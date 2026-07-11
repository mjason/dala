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

export type TerminalActions = {
  reset: () => void;
  refit: () => void;
  focus: () => void;
  /** Deliver text composed in the native input bar: bracketed paste when
   * the foreground app enabled it, plus optional Enter to submit. */
  sendText: (text: string, submit: boolean) => void;
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
        fit.fit();
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

      // Fit and push only when the computed size actually changed — cheap to
      // call from a timer/observer without spamming resizes.
      let lastSize = "";
      const maybeResize = () => {
        if (disposed) return;
        fit.fit();
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
          fit.fit();
          pushResize();
        }
      };
      const reset = () => {
        term.reset();
        refit();
        // Ctrl-L: ask the shell to redraw a fresh prompt after the clear.
        phxChannel.push("input", { data: "\f" });
      };
      const sendText = (text: string, submit: boolean) => {
        if (!gate.acceptInput() || !text) return;
        const data = term.modes.bracketedPasteMode
          ? `\x1b[200~${text}\x1b[201~`
          : text;
        phxChannel.push("input", { data });
        if (submit) phxChannel.push("input", { data: "\r" });
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
      <div ref={containerRef} className="h-full w-full px-3 py-2" />
      <div
        className={`pointer-events-none absolute inset-0 bg-bg0 transition-opacity duration-150 ${
          replaying ? "opacity-100" : "opacity-0"
        }`}
      />
    </div>
  );
}
