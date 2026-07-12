import React, { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import { ClipboardAddon } from "@xterm/addon-clipboard";
import type { IClipboardProvider, ClipboardSelectionType } from "@xterm/addon-clipboard";
import type { Channel } from "phoenix";
import { getSocket } from "./socket";
import {
  createTerminalChannel,
  onTerminalChannelMessages,
  unsubscribeTerminalChannel,
} from "../ash_typed_channels";
import { base64ToBytes, writeClipboard } from "./util";
import { createStreamGate } from "./streamGate";
import { buildCSRFHeaders, savePastedFile } from "../ash_rpc";
import { collectTransferFiles, fileToBase64, pasteName } from "./pasteFiles";
import { fontStack, loadPrefs, onPrefsChange, SMOOTH_SCROLL_MS } from "./termPrefs";
import { createTypeahead } from "./typeahead";
import { isMac } from "./shortcuts";

const theme = {
  background: "#0b0c0e",
  foreground: "#d7dde3",
  cursor: "#4cc38a",
  cursorAccent: "#0b0c0e",
  selectionBackground: "#2d3f4d",
  // xterm 6 draws its own DOM scrollbar (VS Code's scrollable-element) —
  // ::-webkit-scrollbar CSS never touches it; colors come from the theme
  // and the pill shape from app.css.
  // macOS dark-mode overlay thumb is translucent white, not gray.
  scrollbarSliderBackground: "rgba(255, 255, 255, 0.28)",
  scrollbarSliderHoverBackground: "rgba(255, 255, 255, 0.45)",
  scrollbarSliderActiveBackground: "rgba(255, 255, 255, 0.55)",
  black: "#1a1d21",
  red: "#e5716e",
  green: "#5fbf87",
  yellow: "#d9a860",
  blue: "#6d9fd6",
  magenta: "#b087c9",
  cyan: "#5fb8b8",
  white: "#c9ced4",
  brightBlack: "#5b626b",
  brightRed: "#f0928f",
  brightGreen: "#7fd6a3",
  brightYellow: "#ecc57f",
  brightBlue: "#8fb8e8",
  brightMagenta: "#c9a5dd",
  brightCyan: "#7fd0d0",
  brightWhite: "#e6e8eb",
};

// Wait for the bundled font faces (the guaranteed fallback of every stack)
// before the terminal measures its cell size — measuring against a fallback
// font misaligns everything drawn later. User-picked fonts are system fonts
// and need no loading.
function loadTerminalFonts(fontSize: number): Promise<unknown> {
  return Promise.all(
    ["", "bold ", "italic ", "bold italic "].map((variant) =>
      document.fonts.load(`${variant}${fontSize}px "JetBrainsMono NFM"`),
    ),
  ).catch(() => undefined);
}

// A "follower" client (typically a phone) watches a shared session without
// driving its size: it never sends resize, so it can't shrink the PTY for the
// desktop that owns it. Instead it renders at the server's PTY size and scales
// that down to fit its own screen. It can still type.
function isFollowerClient(): boolean {
  if (typeof window === "undefined" || !window.matchMedia) return false;
  return (
    window.matchMedia("(pointer: coarse)").matches &&
    window.matchMedia("(max-width: 820px)").matches
  );
}

/**
 * OSC 52 bridge: lets tmux/zellij/vim inside the terminal write to the
 * system clipboard (their own copy bindings). Reads are refused — a remote
 * program silently reading the clipboard is an exfiltration channel.
 */
class Osc52Provider implements IClipboardProvider {
  readText(_selection: ClipboardSelectionType): Promise<string> {
    return Promise.resolve("");
  }

  writeText(_selection: ClipboardSelectionType, text: string): Promise<void> {
    return writeClipboard(text).then(() => undefined);
  }
}

/** How composed text + Enter reach the foreground app's PTY. Ported from
 * Warp's per-agent rich-input strategies (app/src/terminal/view/
 * use_agent_footer): Codex's paste-burst heuristics swallow a rapid Enter
 * (bracketed paste + immediate CR), while Claude/opencode/Gemini ignore a
 * CR that arrives in the same buffer as the text (bare text + delayed CR). */
export type SendStrategy = "inline" | "bracketed" | "delayed" | "bracketed-delayed";

export type TerminalActions = {
  reset: () => void;
  refit: () => void;
  focus: () => void;
  /** Deliver text composed in the native input bar using the given
   * per-agent strategy (see SendStrategy). */
  sendText: (text: string, submit: boolean, strategy?: SendStrategy) => void;
};

type Props = {
  sessionId: string;
  /** Emulator history lines (session scrollback setting) — xterm keeps the
   * same amount so the server-side history survives in the viewer. */
  scrollbackLines?: number;
  onCwdChange?: (cwd: string) => void;
  onError?: (message: string) => void;
  actionsRef?: React.MutableRefObject<TerminalActions | null>;
  /** Called instead of sending ESC to the shell — but only at a normal
   * prompt: full-screen programs (vim, htop, …) run on the alternate
   * buffer and keep receiving their Escape key. The quick-shell panel
   * uses this to close on Esc. */
  onEscape?: () => void;
};

export default function TerminalView({
  sessionId,
  scrollbackLines,
  onCwdChange,
  onError,
  actionsRef,
  onEscape,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  // Covered while the scrollback replay streams in, so attaching to a
  // session shows the settled screen instead of a visible scroll storm.
  const [replaying, setReplaying] = useState(true);
  const cwdChangeRef = useRef(onCwdChange);
  cwdChangeRef.current = onCwdChange;
  const errorRef = useRef(onError);
  errorRef.current = onError;
  const escapeRef = useRef(onEscape);
  escapeRef.current = onEscape;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    let disposed = false;
    let cleanup: (() => void) | undefined;

    const prefs = loadPrefs();

    void loadTerminalFonts(prefs.fontSize).then(() => {
      if (disposed) return;

      const term = new Terminal({
        theme,
        fontFamily: fontStack(prefs),
        fontSize: prefs.fontSize,
        lineHeight: prefs.lineHeight,
        letterSpacing: 0,
        cursorBlink: prefs.cursorBlink,
        cursorStyle: prefs.cursorStyle,
        smoothScrollDuration: prefs.smoothScroll ? SMOOTH_SCROLL_MS : 0,
        scrollSensitivity: prefs.scrollSensitivity,
        scrollback: scrollbackLines ?? 10_000,
        allowTransparency: false,
        allowProposedApi: true,
      });
      const fit = new FitAddon();
      term.loadAddon(fit);
      term.loadAddon(new WebLinksAddon());
      term.loadAddon(new ClipboardAddon(undefined, new Osc52Provider()));
      term.loadAddon(new Unicode11Addon());
      term.unicode.activeVersion = "11";
      term.open(container);

      // WebGL renderer places every glyph on the exact cell grid (like VS
      // Code), which keeps full-screen apps such as vim pixel-aligned. Fall
      // back to the DOM renderer when WebGL isn't available.
      let webgl: WebglAddon | undefined;
      try {
        webgl = new WebglAddon();
        webgl.onContextLoss(() => {
          webgl?.dispose();
          webgl = undefined;
        });
        term.loadAddon(webgl);
      } catch {
        webgl = undefined;
      }
      // Surfaced in the appearance settings: a silent DOM fallback is the
      // usual culprit when scrolling feels sluggish.
      document.documentElement.dataset.termRenderer = webgl ? "webgl" : "dom";

      fit.fit();
      term.focus();

      // WebGL draws to a canvas — there is no DOM text for the browser's
      // native copy — so copying is explicit: Ctrl+C copies when a selection
      // exists (and interrupts the shell otherwise, Windows Terminal style),
      // and selecting copies immediately when the preference is on. macOS
      // keeps Ctrl+C purely as SIGINT — Cmd+C is the copy key there and goes
      // through xterm's native copy-event path.
      let livePrefs = prefs;
      term.attachCustomKeyEventHandler((event) => {
        if (
          event.type === "keydown" &&
          event.key === "Escape" &&
          escapeRef.current &&
          term.buffer.active.type === "normal"
        ) {
          escapeRef.current();
          return false;
        }
        if (
          !isMac &&
          event.type === "keydown" &&
          event.ctrlKey &&
          !event.shiftKey &&
          !event.altKey &&
          !event.metaKey &&
          (event.key === "c" || event.key === "C") &&
          term.hasSelection()
        ) {
          void writeClipboard(term.getSelection());
          term.clearSelection();
          return false;
        }
        return true;
      });
      const onMouseUp = () => {
        if (livePrefs.copyOnSelect && term.hasSelection()) {
          void writeClipboard(term.getSelection());
        }
      };
      container.addEventListener("mouseup", onMouseUp);

      // Appearance settings apply live to every open terminal.
      const stopPrefsSync = onPrefsChange((next) => {
        livePrefs = next;
        term.options.fontFamily = fontStack(next);
        term.options.fontSize = next.fontSize;
        term.options.lineHeight = next.lineHeight;
        term.options.cursorStyle = next.cursorStyle;
        term.options.cursorBlink = next.cursorBlink;
        term.options.smoothScrollDuration = next.smoothScroll ? SMOOTH_SCROLL_MS : 0;
        term.options.scrollSensitivity = next.scrollSensitivity;
        // Font metrics changed — refit and re-center via the shared path.
        window.setTimeout(() => maybeResize(), 0);
      });

      const follower = isFollowerClient();
      if (follower) {
        container.style.padding = "0";
        container.style.overflow = "auto";
      }

      // Follower only: render at the server's PTY size, then scale that down to
      // fit this screen's width (never resize the shared PTY).
      const scaleToFit = () => {
        const el = term.element;
        if (!el) return;
        el.style.transformOrigin = "top left";
        el.style.transform = "";
        const natural = el.offsetWidth;
        const avail = container.clientWidth;
        if (natural > 0 && avail > 0) {
          el.style.transform = `scale(${Math.min(1, avail / natural)})`;
        }
      };
      const applyServerSize = (rows: number, cols: number) => {
        term.resize(Math.max(cols, 1), Math.max(rows, 1));
        scaleToFit();
      };

      const channel = createTerminalChannel(getSocket(), sessionId);
      const phxChannel = channel as unknown as Channel;

      // See streamGate.ts for the replay/dedup/input-guard invariants.
      const gate = createStreamGate();
      // Optional mosh-style local echo (appearance setting).
      const typeahead = createTypeahead(term, () => livePrefs.localEcho);

      const refs = onTerminalChannelMessages(channel, {
        replay: (payload) => {
          const { reset, release } = gate.replayBatch(payload.seq, payload.done);
          if (reset) {
            typeahead.abandon();
            term.reset();
            setReplaying(true);
          }

          const data = payload.data ? base64ToBytes(payload.data) : "";
          if (release) {
            term.write(data, () => {
              gate.replayParsed();
              term.scrollToBottom();
              setReplaying(false);
            });
          } else {
            term.write(data);
          }
        },
        output: (payload) => {
          if (!gate.acceptOutput(payload.seq)) return;
          term.write(typeahead.reconcile(base64ToBytes(payload.data)));
        },
        cwd: (payload) => {
          cwdChangeRef.current?.(payload.cwd);
        },
      });

      const pushResize = () => {
        phxChannel.push("resize", { rows: term.rows, cols: term.cols });
      };

      // Base inset around the grid; the fit addon subtracts the terminal
      // element's own padding, so it must be set here (not on a parent).
      // After each fit the row/col remainder is split evenly on top of the
      // base so the REAL display area sits centered — TUIs that paint their
      // own background otherwise show all the leftover on the right/bottom.
      const BASE_PAD = { top: 4, right: 10, bottom: 4, left: 10 };
      const resetPadding = () => {
        if (term.element) {
          term.element.style.padding = `${BASE_PAD.top}px ${BASE_PAD.right}px ${BASE_PAD.bottom}px ${BASE_PAD.left}px`;
        }
      };
      const centerPadding = () => {
        const el = term.element;
        const screen = el?.querySelector<HTMLElement>(".xterm-screen");
        if (!el || !screen) return;
        const remX =
          container.clientWidth - BASE_PAD.left - BASE_PAD.right - screen.clientWidth;
        const remY =
          container.clientHeight - BASE_PAD.top - BASE_PAD.bottom - screen.clientHeight;
        const extraX = Math.max(0, remX) / 2;
        const extraY = Math.max(0, remY) / 2;
        el.style.padding =
          `${BASE_PAD.top + extraY}px ${BASE_PAD.right + extraX}px ` +
          `${BASE_PAD.bottom + extraY}px ${BASE_PAD.left + extraX}px`;
      };
      resetPadding();

      // Fit and push only when the computed size actually changed — cheap to
      // call from a timer/observer without spamming resizes.
      //
      // Clamp: at some browser-zoom levels fractional cell metrics make the
      // fit addon propose one row too many — the canvas then overhangs the
      // container and the TUI's bottom row is clipped (or bleeds behind the
      // composer strip). Measure the real overhang after fitting and shave
      // rows off; sticky per container height so it doesn't fight fit().
      let clampFor = "";
      let clampRows = 0;
      const clampOverflow = () => {
        const screen = container.querySelector<HTMLElement>(".xterm-screen");
        if (!screen) return;
        const key = container.clientHeight + "@" + term.rows;
        if (clampFor === key && clampRows > 0) return;
        const overflow = screen.clientHeight - container.clientHeight;
        if (overflow > 2 && term.rows > 4) {
          const cell = screen.clientHeight / term.rows;
          const shave = Math.min(2, Math.max(1, Math.ceil(overflow / cell)));
          term.resize(term.cols, term.rows - shave);
          clampFor = container.clientHeight + "@" + term.rows;
          clampRows = shave;
        } else if (clampFor !== key) {
          clampFor = "";
          clampRows = 0;
        }
      };
      let lastSize = "";
      const maybeResize = () => {
        if (disposed) return;
        resetPadding();
        fit.fit();
        clampOverflow();
        centerPadding();
        const key = term.rows + "x" + term.cols;
        if (key !== lastSize) {
          lastSize = key;
          pushResize();
        }
      };

      // Header-button actions so the user can recover a wedged terminal or
      // recompute width without remembering a shortcut.
      const refit = () => {
        if (follower) scaleToFit();
        else {
          resetPadding();
          fit.fit();
          clampOverflow();
          centerPadding();
          pushResize();
        }
        // A shrunk/grown canvas can keep stale pixels of the previous frame
        // at its edges (the brownish sliver behind the composer strip) —
        // repaint everything after the geometry settles.
        term.refresh(0, term.rows - 1);
      };
      const reset = () => {
        term.reset();
        refit();
        // Ctrl-L: ask the shell to redraw a fresh prompt after the clear.
        phxChannel.push("input", { data: "\f" });
      };
      const sendText = (text: string, submit: boolean, strategy?: SendStrategy) => {
        // Empty text with submit=true is a bare "press Enter" (the composer
        // submits separately after pasting attachments).
        if (!gate.acceptInput() || (!text && !submit)) return;
        const mode: SendStrategy =
          strategy ?? (term.modes.bracketedPasteMode ? "bracketed" : "inline");
        const bracket = mode === "bracketed" || mode === "bracketed-delayed";
        const push = (data: string) => phxChannel.push("input", { data });

        // Claude Code's `!` (bash) / `&` (background) mode prefixes must
        // arrive alone first, so the agent switches modes before the text.
        let body = text;
        let delayExtra = 0;
        if ((body.startsWith("!") || body.startsWith("&")) && body.length > 1 && !bracket) {
          push(body[0]);
          body = body.slice(1);
          delayExtra = 50;
        }

        const sendBody = () => {
          if (body) push(bracket ? `\x1b[200~${body}\x1b[201~` : body);
          if (!submit) return;
          if (mode === "delayed" || mode === "bracketed-delayed") {
            window.setTimeout(() => push("\r"), mode === "bracketed-delayed" ? 300 : 50);
          } else {
            push("\r");
          }
        };
        if (delayExtra) window.setTimeout(sendBody, delayExtra);
        else sendBody();
      };
      if (actionsRef) {
        actionsRef.current = { reset, refit, focus: () => term.focus(), sendText };
      }

      // Fallback: a session with no replay (or a lost done frame) must not
      // stay covered.
      const coverTimer = window.setTimeout(() => setReplaying(false), 2500);

      phxChannel
        .join()
        .receive("ok", (resp?: { rows?: number; cols?: number }) => {
          gate.joined();
          if (follower) {
            if (resp?.rows && resp?.cols) applyServerSize(resp.rows, resp.cols);
            // Attach at the server's size: the repaint is generated for the
            // width this follower renders at.
            phxChannel.push("attach", {
              rows: resp?.rows ?? term.rows,
              cols: resp?.cols ?? term.cols,
            });
          } else {
            // Re-fit now that layout has settled so the PTY is the real size
            // before the user runs anything (else the first `ls` renders at the
            // default 80-col size until a later resize/repaint corrects it).
            fit.fit();
            pushResize();
            // Report the settled viewport; the server resizes the PTY first
            // and only then renders the attach repaint, so its soft wraps
            // match this exact width.
            phxChannel.push("attach", { rows: term.rows, cols: term.cols });
            lastSize = term.rows + "x" + term.cols;
            // Layout/fonts may still be settling right after join/refresh;
            // re-fit on the next ticks so early output is not at a stale size.
            window.setTimeout(maybeResize, 120);
            window.setTimeout(maybeResize, 600);
          }
        })
        .receive("error", () => {
          term.writeln("\x1b[31mcould not attach to session\x1b[0m");
        });

      // Follower: track the owner's PTY size instead of driving our own.
      if (follower) {
        phxChannel.on("resize", (p: { rows: number; cols: number }) => {
          applyServerSize(p.rows, p.cols);
        });
      }

      const inputDisposable = term.onData((data) => {
        if (!gate.acceptInput()) return;
        typeahead.predict(data);
        phxChannel.push("input", { data });
      });

      // Pasting or dropping files (screenshots for Claude Code & co): upload
      // to the server's temp dir and paste the resulting absolute path, like
      // dropping a file onto a native terminal. Text-only pastes fall through
      // to xterm's own handler.
      const uploadFiles = async (files: File[]) => {
        const paths: string[] = [];
        for (const file of files) {
          try {
            const contentBase64 = await fileToBase64(file);
            const result = await savePastedFile({
              input: { name: pasteName(file), contentBase64 },
              fields: ["path"],
              headers: buildCSRFHeaders(),
            });
            if (result.success) {
              paths.push(result.data.path);
            } else {
              errorRef.current?.(result.errors[0]?.message ?? "could not upload pasted file");
            }
          } catch (error) {
            errorRef.current?.(error instanceof Error ? error.message : "could not read file");
          }
        }
        if (paths.length > 0 && !disposed) {
          term.paste(paths.join(" ") + " ");
          term.focus();
        }
      };

      const onPaste = (event: ClipboardEvent) => {
        const files = collectTransferFiles(event.clipboardData);
        if (files.length === 0) return;
        event.preventDefault();
        event.stopPropagation();
        void uploadFiles(files);
      };
      const onDragOver = (event: DragEvent) => event.preventDefault();
      const onDrop = (event: DragEvent) => {
        const files = collectTransferFiles(event.dataTransfer);
        if (files.length === 0) return;
        event.preventDefault();
        void uploadFiles(files);
      };
      // Capture phase so file pastes are intercepted before xterm's textarea.
      container.addEventListener("paste", onPaste, true);
      container.addEventListener("dragover", onDragOver);
      container.addEventListener("drop", onDrop);

      let resizeTimer: number | undefined;
      const observer = new ResizeObserver(() => {
        window.clearTimeout(resizeTimer);
        resizeTimer = window.setTimeout(() => {
          if (follower) scaleToFit();
          else maybeResize();
        }, 60);
      });
      observer.observe(container);

      // Idle self-heal: if the size ever drifts (zoom change, layout race, a
      // missed resize event) re-fit periodically and push only on change.
      const idleTimer = window.setInterval(() => {
        if (follower) scaleToFit();
        else maybeResize();
      }, 2500);

      // Extra triggers a ResizeObserver can miss: window resize, browser zoom
      // (via window resize on most browsers), and the tab becoming visible.
      const onWindowChange = () => {
        if (follower) scaleToFit();
        else maybeResize();
      };
      window.addEventListener("resize", onWindowChange);
      document.addEventListener("visibilitychange", onWindowChange);

      cleanup = () => {
        if (actionsRef) actionsRef.current = null;
        container.removeEventListener("paste", onPaste, true);
        container.removeEventListener("dragover", onDragOver);
        container.removeEventListener("drop", onDrop);
        observer.disconnect();
        window.clearTimeout(coverTimer);
        window.clearTimeout(resizeTimer);
        window.clearInterval(idleTimer);
        window.removeEventListener("resize", onWindowChange);
        document.removeEventListener("visibilitychange", onWindowChange);
        container.removeEventListener("mouseup", onMouseUp);
        stopPrefsSync();
        inputDisposable.dispose();
        typeahead.dispose();
        unsubscribeTerminalChannel(channel, refs);
        phxChannel.leave();
        term.dispose();
      };
    });

    return () => {
      disposed = true;
      cleanup?.();
    };
  }, [sessionId]);

  return (
    <div className="relative h-full w-full">
      {/* Padding lives on .xterm (app.css), NOT here: the fit addon takes
          the parent's computed border-box height and only subtracts the
          terminal element's own padding — parent padding makes it overshoot
          by a row and TUI bottom bars get clipped. */}
      <div ref={containerRef} className="h-full w-full" />
      <div
        className={`pointer-events-none absolute inset-0 bg-bg0 transition-opacity duration-150 ${
          replaying ? "opacity-100" : "opacity-0"
        }`}
      />
    </div>
  );
}
