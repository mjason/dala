import React, { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import { ClipboardAddon } from "@xterm/addon-clipboard";
import type { IClipboardProvider, ClipboardSelectionType } from "@xterm/addon-clipboard";
import { getSocket } from "./socket";
import {
  onTerminalChannelMessages,
  unsubscribeTerminalChannel,
  type TerminalChannel,
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
import { currentTerminalTheme, onThemeChange } from "./theme";
import { createTypeahead } from "./typeahead";
import { useCountdown } from "./hooks/useCountdown";
import { isMac } from "./shortcuts";
import { getDeviceId } from "./deviceId";
import { sizeRole, type SizeRole } from "./sizeRole";
import { useI18n } from "./i18n";

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
  /** Wipe the local emulator, then pull a fresh holder snapshot from the
   * server (reset replay) — repaints even inside TUIs, where asking the
   * app to redraw via a keystroke would be swallowed. */
  reset: () => void;
  /** Recompute the terminal size for THIS screen. `takeover` marks an
   * explicit user action (the 适配宽度 button/shortcut): as a size follower
   * it takes ownership so the PTY reflows to our grid — an explicit claim
   * from another device's ownership, a silent resize from a sibling
   * window's (soft follower). Programmatic refits (composer open/close,
   * restart, kick) must leave ownership alone. */
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

// Sessions that already showed the width-change tip (module memory): one
// takeover tip per session per page load is plenty — repeated takeovers
// must not keep nagging.
const reflowTipSeen = new Set<string>();

// How long the width-change tip stays up (visible countdown, then gone).
const REFLOW_TIP_SECONDS = 5;

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
  // Another DEVICE owns the PTY size: we render at its size scaled to fit,
  // and offer a takeover button in a slim banner. A sibling window of our
  // own device also renders scaled (soft follower) but WITHOUT the banner —
  // the toolbar's explicit refit already retakes silently.
  const [sizeFollower, setSizeFollower] = useState(false);
  // After an explicit takeover that actually changed the PTY width: a
  // dismissable tip about claude code's stale transcript wrapping (it
  // does not rewrap on SIGWINCH — Ctrl+O twice re-renders it). Auto-hides
  // via a visible per-second countdown; × closes immediately.
  const reflowTip = useCountdown();
  // Stable function identities (useCallback inside the hook) — safe for
  // the per-session setup effect below to capture across renders.
  const { start: startReflowTip, clear: hideReflowTip } = reflowTip;
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
        theme: currentTerminalTheme(),
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
          // Mark the key consumed: window-level Escape handlers (fullscreen
          // composer, settings modal) skip defaultPrevented events — one Esc
          // must close exactly one layer.
          event.preventDefault();
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

      // App theme (light/dark) flips apply to every open terminal live:
      // swap the xterm palette and force a repaint. Under WebGL the glyph
      // atlas is keyed on the theme, so a plain refresh re-rasterizes with
      // the new colors; syncWebglCanvas keeps the backing store in step
      // (emulated-DPR contexts). The .xterm-viewport background is CSS
      // (var(--color-bg0)) and follows on its own.
      const stopThemeSync = onThemeChange(() => {
        term.options.theme = currentTerminalTheme();
        syncWebglCanvas();
        term.refresh(0, term.rows - 1);
      });

      // PTY size ownership (server: Dala.Terminal.Server): device-sticky.
      // The join reply and `size_owner` broadcasts report which DEVICE owns
      // the size (live or remembered) and which CLIENT is the live owner.
      // Another device owning → hard follower (scaled render + takeover
      // banner), even while that device is offline. Our device owning but
      // ANOTHER window of it live → soft follower (scaled render, no
      // banner, no resize pushes — same-device windows would thrash the
      // shared PTY otherwise; the explicit refit button retakes silently).
      // Roles can flip any direction at runtime (takeover button, another
      // device claims, a sibling window closes). See sizeRole.ts.
      const deviceId = getDeviceId();
      let clientId: string | null = null;
      let role: SizeRole = "driver";
      // Rendering mode shared by both follower flavors: mirror the owner's
      // grid, scale to fit, never push resizes.
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

      // Not createTerminalChannel (codegen — no join params): the join must
      // carry the stable device id the size ownership sticks to.
      const phxChannel = getSocket().channel(`terminal:${sessionId}`, {
        device_id: deviceId,
      });
      const channel = phxChannel as unknown as TerminalChannel;

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

      // Role transitions. All directions can happen at runtime: another
      // client claims the size while we drive it (owner → follower), a
      // sibling window of this device takes over (driver ↔ soft follower),
      // or ownership frees up / we take it over (follower → owner).
      // `banner` distinguishes the flavors: the manual-claim banner only
      // for ANOTHER device's ownership — a sibling window of our own
      // device follows silently (its refit button already retakes).
      const enterFollower = (rows: number, cols: number, banner: boolean) => {
        follower = true;
        // The driver-path insets would be scaled along with the grid and
        // fight the fit math — the follower renders edge to edge. Both
        // dimensions scale to fit (scaleToFit), so the container never
        // scrolls and touch pans stay with the terminal scrollback.
        if (term.element) term.element.style.padding = "0";
        applyServerSize(rows, cols);
        // Demoted: the takeover tip's slot belongs to the follower banner
        // now (and the advice is stale — someone else drives the width).
        hideReflowTip();
        setSizeFollower(banner);
      };
      // An explicit takeover just rewrapped the PTY to a different width:
      // remind (once per session) that claude code does not rewrap its
      // transcript on SIGWINCH — Ctrl+O twice does. Auto-hides after a
      // visible 5s countdown (useCountdown owns the interval); × closes.
      const showReflowTip = () => {
        if (reflowTipSeen.has(sessionId)) return;
        reflowTipSeen.add(sessionId);
        startReflowTip(REFLOW_TIP_SECONDS);
      };

      // `claim`: how to assert ownership server-side — a plain resize when
      // the device memory already lets us drive (free, ours, or a sibling
      // window's: "resize"), or the explicit takeover event ("claim").
      const enterDriver = (claim: "resize" | "claim") => {
        role = "driver";
        follower = false;
        if (term.element) term.element.style.transform = "";
        resetPadding();
        const prevCols = term.cols;
        fit.fit();
        clampOverflow();
        centerPadding();
        syncWebglCanvas();
        lastSize = term.rows + "x" + term.cols;
        if (claim === "resize") pushResize();
        if (claim === "claim") {
          phxChannel.push("claim_size", { rows: term.rows, cols: term.cols });
          // Only the explicit takeover flavor, and only when the width
          // really changed (re-claiming the same grid rewraps nothing).
          if (term.cols !== prevCols) showReflowTip();
        }
        // Repaint after the geometry settles (stale edge pixels otherwise).
        term.refresh(0, term.rows - 1);
        setSizeFollower(false);
      };
      claimSizeRef.current = () => enterDriver("claim");

      // One entry point for every server ownership report (join reply and
      // `size_owner` broadcasts): derive the role, transition the rendering
      // mode, and keep the banner in sync (hard follower only).
      const applyOwnership = (p: {
        owner?: string | null;
        owner_device?: string | null;
        rows?: number;
        cols?: number;
      }): SizeRole => {
        const next = sizeRole(deviceId, clientId, p);
        if (next === "driver") {
          // Our device holds the size (or the session is unadopted) while
          // we still render as follower — our own takeover confirming, or
          // the live sibling window closed. Push our real fitted size so
          // the PTY reflows to the grid we are about to render; the plain
          // resize applies silently because the device memory is ours.
          if (follower) enterDriver("resize");
          role = "driver";
        } else {
          role = next;
          enterFollower(p.rows ?? term.rows, p.cols ?? term.cols, next === "follower");
        }
        return role;
      };

      // Header-button actions so the user can recover a wedged terminal or
      // recompute width without remembering a shortcut.
      const refit = (takeover = false) => {
        if (follower) {
          if (takeover) {
            // The explicit Refit action means "fit to MY screen" — for a
            // follower that is a takeover: reflow the PTY to our grid
            // instead of re-scaling someone else's width into the corner.
            // Another device's ownership needs the explicit claim (it
            // rewrites the device memory); a sibling window of our own
            // device is retaken silently by a plain resize.
            enterDriver(role === "follower" ? "claim" : "resize");
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
        // `takeover` marks the explicit user action (button/shortcut) — the
        // click stole focus from the terminal, give it back. Programmatic
        // refits (composer toggle, restart, …) must NOT steal focus.
        if (takeover) term.focus();
      };
      const reset = () => {
        term.reset();
        refit();
        // Ask the server for a fresh holder snapshot, delivered to this
        // client as a reset replay. (A \f keystroke would only redraw a bare
        // shell prompt — zellij/claude-code/any TUI swallows it, leaving the
        // just-blanked terminal dead until a session switch re-attaches.)
        phxChannel.push("repaint", {});
        // The button click stole focus from the terminal.
        term.focus();
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
            owner_device?: string | null;
            client_id?: string;
          }) => {
            gate.joined();
            clientId = resp?.client_id ?? null;
            if (applyOwnership(resp ?? {}) !== "driver") {
              // Someone else drives the size — another device (hard
              // follower, banner) or a sibling window of this device (soft
              // follower, silent): render at the PTY's size, scaled to
              // fit, and attach at that same size so the repaint's soft
              // wraps match what we display.
              phxChannel.push("attach", {
                rows: resp?.rows ?? term.rows,
                cols: resp?.cols ?? term.cols,
              });
            } else {
              // The session is unadopted (we adopt it) or already ours:
              // drive our own size — this resize claims/re-owns it
              // silently. Re-fit now that layout has settled so the
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

      // Ownership changes at runtime: somebody claimed the size (maybe us,
      // maybe a sibling window of this device). A live owner disconnecting
      // is only up for grabs within the owner device: the device memory
      // keeps other devices followers, while a soft follower promotes
      // itself back to driver when its sibling window goes away.
      phxChannel.on(
        "size_owner",
        (p: {
          owner?: string | null;
          owner_device?: string | null;
          rows?: number;
          cols?: number;
        }) => {
          applyOwnership(p);
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
        hideReflowTip();
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
        stopThemeSync();
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
      {reflowTip.seconds != null && !sizeFollower && (
        <div
          id="reflow-tip"
          className="absolute inset-x-0 top-0 z-10 flex items-center justify-center gap-3 border-b border-line bg-bg1/90 px-3 py-1 backdrop-blur-sm pointer-coarse:py-2"
        >
          <span className="font-mono text-[11px] text-fg-muted pointer-coarse:text-[13px]">
            {t("reflowTip")}
          </span>
          <span
            id="reflow-tip-countdown"
            className="font-mono text-[10px] tabular-nums text-fg-muted/60 pointer-coarse:text-[12px]"
          >
            {reflowTip.seconds}s
          </span>
          <button
            id="reflow-tip-close"
            aria-label={t("close")}
            onClick={() => hideReflowTip()}
            className="rounded border border-line px-2 py-0.5 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg pointer-coarse:px-3 pointer-coarse:py-1.5 pointer-coarse:text-[13px]"
          >
            ×
          </button>
        </div>
      )}
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
