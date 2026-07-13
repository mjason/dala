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
import { createAckCounter } from "./flowControl";
import { collectTransferFiles } from "./pasteFiles";
import { pastedPathsText, uploadPastedFiles } from "./pastedFileUpload";
import { resolveSendMode, sendComposedText, type SendStrategy } from "./terminalSend";
import {
  createLineAccumulator,
  createTouchPan,
  decayVelocity,
  MIN_COAST_VELOCITY,
  touchScrollRoute,
} from "./touchScroll";
import { fontStack, loadPrefs, onPrefsChange, SMOOTH_SCROLL_MS } from "./termPrefs";
import { createTypeahead } from "./typeahead";
import { isMac } from "./shortcuts";
import { isSizeFollower } from "./sizeRole";
import { useI18n } from "./i18n";

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

export type { SendStrategy } from "./terminalSend";

export type TerminalActions = {
  reset: () => void;
  /** Recompute the terminal size for THIS screen. `takeover` marks an
   * explicit user action (the 适配宽度 button/shortcut): as a size follower
   * it claims ownership so the PTY reflows to our grid. Programmatic refits
   * (composer open/close, restart, kick) must leave ownership alone. */
  refit: (takeover?: boolean) => void;
  focus: () => void;
  /** Deliver text composed in the native input bar using the given
   * per-agent strategy (see SendStrategy). */
  sendText: (text: string, submit: boolean, strategy?: SendStrategy) => void;
  /** Push raw bytes (escape sequences from the touch key bar) straight down
   * the regular input path — no framing, no strategies. */
  sendKey: (data: string) => void;
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
  /** Optional rewrite of user keystrokes before they reach the PTY. App
   * uses it for the touch key bar's sticky Ctrl: the next single character
   * typed on the soft keyboard becomes its control byte. */
  inputHookRef?: React.MutableRefObject<((data: string) => string) | null>;
  /** Expose this terminal as `window.__dalaTerm` (debug/e2e handle). Only
   * the MAIN session view sets it — overlay terminals (quick shells) must
   * not steal the handle from the session the tests read. */
  debugHandle?: boolean;
};

export default function TerminalView({
  sessionId,
  scrollbackLines,
  onCwdChange,
  onError,
  actionsRef,
  onEscape,
  inputHookRef,
  debugHandle,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  // Covered while the scrollback replay streams in, so attaching to a
  // session shows the settled screen instead of a visible scroll storm.
  const [replaying, setReplaying] = useState(true);
  // Another client owns the PTY size: we render at its size scaled to fit,
  // and offer a takeover button in a slim banner.
  const [sizeFollower, setSizeFollower] = useState(false);
  const claimSizeRef = useRef<(() => void) | null>(null);
  const { t } = useI18n();
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
        // Font metrics changed — refit/re-scale via the shared path.
        window.setTimeout(() => relayout(), 0);
      });

      // PTY size ownership (server: Dala.Terminal.Server): the join reply and
      // `size_owner` broadcasts tell this client whether ANOTHER client owns
      // the size. While it does, we are a follower: render at the owner's PTY
      // size scaled down to fit, never push resize. Roles can flip both ways
      // at runtime (owner leaves, takeover button, another client claims).
      let clientId: string | null = null;
      let follower = false;

      // Chromium's DPR emulation (DevTools device mode, playwright mobile
      // contexts) breaks the webgl addon's canvas sizing: the addon sets its
      // backing store from a `device-pixel-content-box` ResizeObserver, which
      // Chromium reports in HOST device pixels — ignoring the emulated
      // devicePixelRatio — while the renderer's gl.viewport uses emulated
      // device pixels. The drawable buffer then holds only an empty corner of
      // the frame and the terminal paints NOTHING. Re-sync the backing store
      // to the renderer's own device dimensions; on real displays both
      // already match and this is a no-op.
      const syncWebglCanvas = () => {
        if (!webgl) return;
        try {
          const renderer = (
            term as unknown as {
              _core?: {
                _renderService?: {
                  _renderer?: {
                    value?: {
                      _canvas?: HTMLCanvasElement;
                      dimensions?: {
                        device?: { canvas?: { width: number; height: number } };
                      };
                    };
                  };
                };
              };
            }
          )._core?._renderService?._renderer?.value;
          const canvas = renderer?._canvas;
          const device = renderer?.dimensions?.device?.canvas;
          if (!canvas || !device || device.width <= 0 || device.height <= 0) return;
          if (canvas.width !== device.width || canvas.height !== device.height) {
            canvas.width = device.width;
            canvas.height = device.height;
            term.refresh(0, term.rows - 1);
          }
        } catch {
          // Private xterm internals moved — the addon then keeps sizing
          // itself, which is correct everywhere except emulated-DPR contexts.
        }
      };
      // The addon's own observer can overwrite the fix on any layout change;
      // watch its canvas and re-correct right after (created later than the
      // addon's observer, so it runs after it).
      let canvasObserver: ResizeObserver | undefined;
      {
        const canvas = (
          term as unknown as {
            _core?: { _renderService?: { _renderer?: { value?: { _canvas?: HTMLCanvasElement } } } };
          }
        )._core?._renderService?._renderer?.value?._canvas;
        if (canvas) {
          canvasObserver = new ResizeObserver(() => syncWebglCanvas());
          canvasObserver.observe(canvas);
        }
      }

      // Follower only: render at the owner's PTY size, then scale the whole
      // terminal down so the FULL grid — both dimensions — fits this screen
      // (never resize the shared PTY). Scaling height too (instead of
      // overflow scrolling the container) keeps touch pans owned by the
      // terminal's own scrollback handling. The block element `.xterm`
      // always fills the container — its offsetWidth says nothing about the
      // grid — so measure the grid itself (.xterm-screen; offset sizes are
      // layout sizes, unaffected by the transform we set).
      const scaleToFit = () => {
        const el = term.element;
        const screen = el?.querySelector<HTMLElement>(".xterm-screen");
        if (!el || !screen) return;
        el.style.transformOrigin = "top left";
        const naturalW = screen.offsetWidth;
        const naturalH = screen.offsetHeight;
        const availW = container.clientWidth;
        const availH = container.clientHeight;
        if (naturalW <= 0 || naturalH <= 0 || availW <= 0 || availH <= 0) {
          el.style.transform = "";
          return;
        }
        const scale = Math.min(availW / naturalW, availH / naturalH, 1);
        el.style.transform = scale < 1 ? `scale(${scale})` : "";
      };
      const applyServerSize = (rows: number, cols: number) => {
        term.resize(Math.max(cols, 1), Math.max(rows, 1));
        syncWebglCanvas();
        scaleToFit();
      };

      const channel = createTerminalChannel(getSocket(), sessionId);
      const phxChannel = channel as unknown as Channel;

      // See streamGate.ts for the replay/dedup/input-guard invariants.
      const gate = createStreamGate();
      // Optional mosh-style local echo (appearance setting).
      const typeahead = createTypeahead(term, () => livePrefs.localEcho);

      // Flow control: acknowledge bytes once xterm has PARSED them, so the
      // server can bound the in-flight backlog per client (and skip-to-
      // repaint on slow links). Counting parsed bytes — not received ones —
      // also covers renderer backpressure.
      const flowStats = ((window as unknown as Record<string, unknown>).__dalaFlow = {
        acked: 0,
        resets: 0,
      });
      // Debug/e2e handle: WebGL leaves no text in the DOM, so tests read the
      // emulator buffer through this instead of scraping HTML. Only the main
      // session view (debugHandle) binds it — see the Props doc.
      if (debugHandle) {
        (window as unknown as Record<string, unknown>).__dalaTerm = term;
      }
      const ackCounter = createAckCounter((bytes, alt) => {
        flowStats.acked += bytes;
        phxChannel.push("ack", { bytes, alt });
      });
      const writeCounted = (data: Uint8Array | string, done?: () => void) => {
        const size = typeof data === "string" ? data.length : data.byteLength;
        term.write(data, () => {
          ackCounter.consumed(size, term.buffer.active.type === "alternate");
          done?.();
        });
      };

      const refs = onTerminalChannelMessages(channel, {
        replay: (payload) => {
          // reset flag = mid-session flow-control snapshot: treat it as a
          // fresh join so the screen clears and the seq baseline moves.
          if ((payload as { reset?: boolean }).reset) {
            gate.joined();
            flowStats.resets += 1;
          }
          const { reset, release } = gate.replayBatch(payload.seq, payload.done);
          if (reset) {
            typeahead.abandon();
            term.reset();
            setReplaying(true);
          }

          const data = payload.data ? base64ToBytes(payload.data) : "";
          if (release) {
            writeCounted(data, () => {
              gate.replayParsed();
              term.scrollToBottom();
              setReplaying(false);
            });
          } else {
            writeCounted(data);
          }
        },
        output: (payload) => {
          if (!gate.acceptOutput(payload.seq)) return;
          writeCounted(typeahead.reconcile(base64ToBytes(payload.data)));
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
        syncWebglCanvas();
        const key = term.rows + "x" + term.cols;
        if (key !== lastSize) {
          lastSize = key;
          pushResize();
        }
      };
      // Timer/observer entry point that respects the current size role.
      const relayout = () => {
        if (disposed) return;
        if (follower) {
          syncWebglCanvas();
          scaleToFit();
        } else {
          maybeResize();
        }
      };

      // Role transitions. Both directions can happen at runtime: another
      // client claims the size while we drive it (owner → follower), or
      // ownership frees up / we take it over (follower → owner).
      const enterFollower = (rows: number, cols: number) => {
        const wasDriver = !follower;
        follower = true;
        // The driver-path insets would be scaled along with the grid and
        // fight the fit math — the follower renders edge to edge. Both
        // dimensions scale to fit (scaleToFit), so the container never
        // scrolls and touch pans stay with the terminal scrollback.
        if (term.element) term.element.style.padding = "0";
        applyServerSize(rows, cols);
        if (wasDriver) setSizeFollower(true);
      };
      // `claim`: how to assert ownership server-side — a plain resize when
      // ownership is free or already confirmed ours ("resize"), or the
      // explicit takeover event ("claim").
      const enterDriver = (claim: "resize" | "claim") => {
        const wasFollower = follower;
        follower = false;
        if (term.element) term.element.style.transform = "";
        resetPadding();
        fit.fit();
        clampOverflow();
        centerPadding();
        syncWebglCanvas();
        lastSize = term.rows + "x" + term.cols;
        if (claim === "resize") pushResize();
        if (claim === "claim")
          phxChannel.push("claim_size", { rows: term.rows, cols: term.cols });
        // Repaint after the geometry settles (stale edge pixels otherwise).
        term.refresh(0, term.rows - 1);
        if (wasFollower) setSizeFollower(false);
      };
      claimSizeRef.current = () => enterDriver("claim");

      // Header-button actions so the user can recover a wedged terminal or
      // recompute width without remembering a shortcut.
      const refit = (takeover = false) => {
        if (follower) {
          if (takeover) {
            // The explicit Refit action means "fit to MY screen" — for a
            // follower that is a takeover: claim the size so the PTY
            // reflows to our grid instead of re-scaling someone else's
            // width into the corner.
            enterDriver("claim");
          } else {
            // Programmatic refits (composer toggle, restart, …) keep the
            // follower role: just re-sync the scaled rendering.
            syncWebglCanvas();
            scaleToFit();
          }
        } else {
          resetPadding();
          fit.fit();
          clampOverflow();
          centerPadding();
          syncWebglCanvas();
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
        const mode = resolveSendMode(strategy, term.modes.bracketedPasteMode);
        sendComposedText(text, submit, mode, (data) =>
          phxChannel.push("input", { data }),
        );
      };
      const sendKey = (data: string) => {
        if (!gate.acceptInput() || !data) return;
        phxChannel.push("input", { data });
      };
      if (actionsRef) {
        actionsRef.current = { reset, refit, focus: () => term.focus(), sendText, sendKey };
      }

      // Fallback: a session with no replay (or a lost done frame) must not
      // stay covered.
      const coverTimer = window.setTimeout(() => setReplaying(false), 2500);

      phxChannel
        .join()
        .receive(
          "ok",
          (resp?: {
            rows?: number;
            cols?: number;
            owner?: string | null;
            client_id?: string;
          }) => {
            gate.joined();
            clientId = resp?.client_id ?? null;
            if (isSizeFollower(clientId, resp?.owner)) {
              // Another client owns the size: render at the PTY's size,
              // scaled to fit, and attach at that same size so the repaint's
              // soft wraps match what we display.
              enterFollower(resp?.rows ?? term.rows, resp?.cols ?? term.cols);
              phxChannel.push("attach", {
                rows: resp?.rows ?? term.rows,
                cols: resp?.cols ?? term.cols,
              });
            } else {
              // Ownership is free (or ours): drive our own size — this
              // resize claims it. Re-fit now that layout has settled so the
              // PTY is the real size before the user runs anything (else the
              // first `ls` renders at the default 80-col size until a later
              // resize/repaint corrects it).
              fit.fit();
              pushResize();
              // Report the settled viewport; the server resizes the PTY
              // first and only then renders the attach repaint, so its soft
              // wraps match this exact width.
              phxChannel.push("attach", { rows: term.rows, cols: term.cols });
              lastSize = term.rows + "x" + term.cols;
              // Layout/fonts may still be settling right after join/refresh;
              // re-fit on the next ticks so early output is not at a stale
              // size.
              window.setTimeout(relayout, 120);
              window.setTimeout(relayout, 600);
            }
          },
        )
        .receive("error", () => {
          term.writeln("\x1b[31mcould not attach to session\x1b[0m");
        });

      // Ownership changes at runtime: somebody claimed the size (maybe us),
      // or the owner left and the size is up for grabs.
      phxChannel.on(
        "size_owner",
        (p: { owner?: string | null; rows?: number; cols?: number }) => {
          if (isSizeFollower(clientId, p.owner)) {
            enterFollower(p.rows ?? term.rows, p.cols ?? term.cols);
          } else if (p.owner == null) {
            // Ownership freed (the owner disconnected): drive our own size —
            // the resize claims it. Last write wins if several clients race.
            enterDriver("resize");
          } else if (follower) {
            // We are the owner while still rendering as follower. Usually
            // our own takeover confirming; but it can also be an ACCIDENTAL
            // claim (our follower attach raced the old owner leaving and
            // claimed at ITS dims) — push our real fitted size so the PTY
            // reflows to the grid we are about to render.
            enterDriver("resize");
          }
        },
      );

      // Follower: track the owner's PTY size instead of driving our own.
      phxChannel.on("resize", (p: { rows: number; cols: number }) => {
        if (follower) applyServerSize(p.rows, p.cols);
      });

      const inputDisposable = term.onData((data) => {
        if (!gate.acceptInput()) return;
        const hooked = inputHookRef?.current?.(data) ?? data;
        typeahead.predict(hooked);
        phxChannel.push("input", { data: hooked });
      });

      // Pasting or dropping files (screenshots for Claude Code & co): upload
      // to the server's temp dir and paste the resulting absolute path, like
      // dropping a file onto a native terminal. Text-only pastes fall through
      // to xterm's own handler.
      const uploadFiles = async (files: File[]) => {
        const paths = await uploadPastedFiles(files, (message) =>
          errorRef.current?.(message),
        );
        if (paths.length > 0 && !disposed) {
          term.paste(pastedPathsText(paths));
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

      // ---- Touch scrolling (phones/tablets) -------------------------------
      // xterm 6 has NO touch handling at all: v5's `.xterm-viewport` was a
      // native `overflow-y: scroll` element (panning worked for free), v6
      // replaced it with VS Code's ScrollableElement which only listens to
      // wheel events — so on mobile a one-finger pan does nothing. Convert
      // vertical pans here (math in touchScroll.ts):
      //  - normal buffer → term.scrollLines(), 1 touch px ≈ 1 scroll px
      //    (line-quantized, like every wheel scroll), plus flick inertia;
      //  - alt-screen TUIs / mouse-tracking apps → synthetic per-line
      //    WheelEvents on `.xterm`, which run xterm's own wheel→arrow-key
      //    conversion (less, vim) or mouse reports (mouse-mode TUIs).
      // Gated on a coarse PRIMARY pointer, same policy as TouchKeyBar:
      // desktops (even with touchscreens) see zero behavior change.
      const coarseQuery =
        typeof window.matchMedia === "function"
          ? window.matchMedia("(pointer: coarse)")
          : null;
      const touchPan = createTouchPan();
      const panLines = createLineAccumulator();
      let inertiaFrame: number | undefined;
      const stopInertia = () => {
        if (inertiaFrame !== undefined) {
          window.cancelAnimationFrame(inertiaFrame);
          inertiaFrame = undefined;
        }
      };
      const cellHeight = () => {
        const screen = container.querySelector<HTMLElement>(".xterm-screen");
        const h = screen && term.rows > 0 ? screen.clientHeight / term.rows : 0;
        return h > 0 ? h : 17;
      };
      const scrollRoute = () =>
        touchScrollRoute(term.buffer.active.type, term.modes.mouseTrackingMode);
      const applyPanLines = (lines: number, clientX: number, clientY: number) => {
        if (lines === 0) return;
        if (scrollRoute() === "lines") {
          term.scrollLines(lines);
          return;
        }
        // One wheel event per line: xterm sends exactly one arrow key (or
        // one mouse report) per wheel event, whatever its magnitude.
        // DOM_DELTA_LINE keeps consumeWheelEvent's math at 1 event = 1 line
        // (pixel mode applies trackpad damping). Dispatched on `.xterm`
        // itself — below the ScrollableElement's own listener, so the
        // scrollback stays untouched.
        const target = term.element;
        if (!target) return;
        const step = lines > 0 ? 1 : -1;
        for (let i = Math.abs(lines); i > 0; i--) {
          target.dispatchEvent(
            new WheelEvent("wheel", {
              bubbles: true,
              cancelable: true,
              deltaMode: WheelEvent.DOM_DELTA_LINE,
              deltaY: step,
              clientX,
              clientY,
            }),
          );
        }
      };
      // Flick inertia — scrollback only: a decaying arrow-key storm would
      // overshoot in alt-screen TUIs, so those stop dead on release.
      const startInertia = (releaseVelocity: number) => {
        if (releaseVelocity === 0 || scrollRoute() !== "lines") return;
        let v = releaseVelocity;
        let last: number | undefined;
        const frame = (now: number) => {
          inertiaFrame = undefined;
          if (last !== undefined) {
            const dt = now - last;
            v = decayVelocity(v, dt);
            if (Math.abs(v) < MIN_COAST_VELOCITY || scrollRoute() !== "lines") return;
            const lines = panLines.add(v * dt, cellHeight());
            if (lines !== 0) term.scrollLines(lines);
          }
          last = now;
          inertiaFrame = window.requestAnimationFrame(frame);
        };
        inertiaFrame = window.requestAnimationFrame(frame);
      };
      const onTouchStart = (event: TouchEvent) => {
        if (!coarseQuery?.matches) return;
        stopInertia();
        panLines.reset();
        if (event.touches.length !== 1) {
          touchPan.cancel();
          return;
        }
        const t = event.touches[0];
        touchPan.start(t.clientX, t.clientY, event.timeStamp);
      };
      const onTouchMove = (event: TouchEvent) => {
        if (event.touches.length !== 1) {
          touchPan.cancel();
          return;
        }
        const t = event.touches[0];
        const update = touchPan.move(t.clientX, t.clientY, event.timeStamp);
        if (update.phase !== "pan") return;
        // We own this vertical gesture: keep the browser from panning/
        // rubber-banding the page. Taps and horizontal gestures never get
        // here, so focus/selection behavior stays untouched.
        event.preventDefault();
        applyPanLines(panLines.add(update.scrollPx, cellHeight()), t.clientX, t.clientY);
      };
      const onTouchEnd = (event: TouchEvent) => {
        if (event.touches.length > 0) return;
        startInertia(touchPan.end(event.timeStamp));
      };
      const onTouchCancel = () => {
        touchPan.cancel();
      };
      container.addEventListener("touchstart", onTouchStart, { passive: true });
      container.addEventListener("touchmove", onTouchMove, { passive: false });
      container.addEventListener("touchend", onTouchEnd, { passive: true });
      container.addEventListener("touchcancel", onTouchCancel, { passive: true });

      let resizeTimer: number | undefined;
      const observer = new ResizeObserver(() => {
        window.clearTimeout(resizeTimer);
        resizeTimer = window.setTimeout(relayout, 60);
      });
      observer.observe(container);

      // Idle self-heal: if the size ever drifts (zoom change, layout race, a
      // missed resize event) re-fit periodically and push only on change.
      const idleTimer = window.setInterval(relayout, 2500);

      // Extra triggers a ResizeObserver can miss: window resize, browser zoom
      // (via window resize on most browsers), and the tab becoming visible.
      const onWindowChange = () => relayout();
      window.addEventListener("resize", onWindowChange);
      document.addEventListener("visibilitychange", onWindowChange);

      cleanup = () => {
        if (actionsRef) actionsRef.current = null;
        // Only drop the debug handle when it is still OURS — a newer view
        // (session switch) may have rebound it already.
        const w = window as unknown as Record<string, unknown>;
        if (w.__dalaTerm === term) delete w.__dalaTerm;
        claimSizeRef.current = null;
        setSizeFollower(false);
        container.removeEventListener("paste", onPaste, true);
        container.removeEventListener("dragover", onDragOver);
        container.removeEventListener("drop", onDrop);
        stopInertia();
        container.removeEventListener("touchstart", onTouchStart);
        container.removeEventListener("touchmove", onTouchMove);
        container.removeEventListener("touchend", onTouchEnd);
        container.removeEventListener("touchcancel", onTouchCancel);
        observer.disconnect();
        canvasObserver?.disconnect();
        window.clearTimeout(coverTimer);
        window.clearTimeout(resizeTimer);
        window.clearInterval(idleTimer);
        window.removeEventListener("resize", onWindowChange);
        document.removeEventListener("visibilitychange", onWindowChange);
        container.removeEventListener("mouseup", onMouseUp);
        stopPrefsSync();
        inputDisposable.dispose();
        typeahead.dispose();
        ackCounter.dispose();
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
      {sizeFollower && (
        <div
          id="size-follower-banner"
          className="absolute inset-x-0 top-0 z-10 flex items-center justify-center gap-3 border-b border-line bg-bg1/90 px-3 py-1 backdrop-blur-sm pointer-coarse:py-2"
        >
          <span className="font-mono text-[11px] text-fg-muted pointer-coarse:text-[13px]">
            {t("sizeFollowerBanner")}
          </span>
          <button
            id="claim-size-button"
            onClick={() => claimSizeRef.current?.()}
            className="rounded border border-line px-2 py-0.5 font-mono text-[11px] text-mint transition-colors hover:border-mint pointer-coarse:px-3 pointer-coarse:py-1.5 pointer-coarse:text-[13px]"
          >
            {t("sizeFollowerTakeover")}
          </button>
        </div>
      )}
      <div
        className={`pointer-events-none absolute inset-0 bg-bg0 transition-opacity duration-150 ${
          replaying ? "opacity-100" : "opacity-0"
        }`}
      />
    </div>
  );
}
