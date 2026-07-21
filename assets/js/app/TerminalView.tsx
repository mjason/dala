import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import { ClipboardAddon } from "@xterm/addon-clipboard";
import type { IClipboardProvider, ClipboardSelectionType } from "@xterm/addon-clipboard";
import { SearchAddon } from "@xterm/addon-search";
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
import type { UploadProgress } from "./fileUpload";
import UploadProgressView from "./UploadProgressView";
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
import { createHiddenOutputBuffer } from "./hiddenOutputBuffer";
import { createLazyHistory, type HistoryIntent } from "./lazyHistory";
import { recoverOwnedWebglContext } from "./rendererLifecycle";
import {
  replayBatchPlan,
  replayCoverTransition,
  replayPresentation,
  shouldDiscardHiddenOutput,
  type ReplayPresentation,
  type ReplayTrigger,
} from "./replayPresentation";

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
  onPlatform?: (platform: "windows" | "macos" | "linux") => void;
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
  /** Pooled views: false = kept alive but hidden (visibility:hidden). A
   * hidden view keeps its channel and live output; only the shared
   * actionsRef/debug-handle claims and focus follow visibility. */
  visible?: boolean;
};

// Sessions that already showed the width-change tip (module memory): one
// takeover tip per session per page load is plenty — repeated takeovers
// must not keep nagging.
const reflowTipSeen = new Set<string>();

// How long the width-change tip stays up (visible countdown, then gone).
const REFLOW_TIP_SECONDS = 5;
const HIDDEN_OUTPUT_LIMIT = 128 * 1024;

export default function TerminalView({
  sessionId,
  scrollbackLines,
  onCwdChange,
  onError,
  onPlatform,
  actionsRef,
  onEscape,
  inputHookRef,
  debugHandle,
  visible = true,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  // The mount closure reads visibility through refs (it runs once).
  const visibleRef = useRef(visible);
  visibleRef.current = visible;
  const localActionsRef = useRef<TerminalActions | null>(null);
  const relayoutRef = useRef<((force?: boolean) => void) | null>(null);
  const visibilityActionRef = useRef<(nextVisible: boolean) => void>(() => {});
  const loadHistoryRef = useRef<(intent: HistoryIntent) => boolean>(() => false);
  // Covered while the scrollback replay streams in, so attaching to a
  // session shows the settled screen instead of a visible scroll storm.
  const [replaying, setReplaying] = useState(true);
  // A pooled view can already have a perfectly usable frame when a bounded
  // catch-up is requested. Keep that frame visible while xterm parses the
  // replacement snapshot; cold attaches and explicit resets still use the
  // cover so partially rendered state is never exposed.
  const hasRenderedFrameRef = useRef(false);
  const replayTriggerRef = useRef<ReplayTrigger>("initial");
  const replayPresentationRef = useRef<ReplayPresentation>("cover");
  const flowStatsRef = useRef<object | null>(null);
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
  const uploadAbortRef = useRef<AbortController | null>(null);
  const [uploadProgress, setUploadProgress] = useState<UploadProgress | null>(null);
  const escapeRef = useRef(onEscape);
  escapeRef.current = onEscape;

  // Terminal find (Ctrl/Cmd+F): search the scrollback via SearchAddon. WebGL
  // renders to a canvas with no DOM text, so the browser's native find is
  // useless here — this box drives the addon and highlights matches instead.
  const termRef = useRef<Terminal | null>(null);
  const searchRef = useRef<SearchAddon | null>(null);
  const findInputRef = useRef<HTMLInputElement>(null);
  const [findOpen, setFindOpen] = useState(false);
  const [findQuery, setFindQuery] = useState("");
  const findQueryRef = useRef(findQuery);
  findQueryRef.current = findQuery;
  const [findCount, setFindCount] = useState<{ index: number; count: number }>({
    index: -1,
    count: 0,
  });
  // Called from the imperative key handler (set up once) — kept in a ref so it
  // always sees the latest React setters.
  const openFindRef = useRef(() => {});
  openFindRef.current = () => {
    loadHistoryRef.current("find");
    setFindOpen(true);
    requestAnimationFrame(() => findInputRef.current?.select());
  };
  const runFind = (dir: 1 | -1, query: string, incremental = false) => {
    const s = searchRef.current;
    if (!s) return;
    if (!query) {
      s.clearDecorations();
      setFindCount({ index: -1, count: 0 });
      return;
    }
    const opts = {
      decorations: {
        matchBackground: "#facc1566",
        matchBorder: "#facc1500",
        matchOverviewRuler: "#facc15",
        activeMatchBackground: "#2dd4bf",
        activeMatchColorOverviewRuler: "#2dd4bf",
      },
      caseSensitive: false,
      incremental,
    };
    if (dir === 1) s.findNext(query, opts);
    else s.findPrevious(query, opts);
  };
  const closeFind = () => {
    setFindOpen(false);
    searchRef.current?.clearDecorations();
    setFindCount({ index: -1, count: 0 });
    termRef.current?.focus();
  };

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // The effect is recreated for a new session id while the component is
    // pooled. The old session's settled-frame state must never make the new
    // session skip its cold-attach cover.
    hasRenderedFrameRef.current = false;
    replayTriggerRef.current = "initial";
    replayPresentationRef.current = "cover";
    setReplaying(true);

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
      let webglGeneration = 0;
      let webglRetryTimer: number | undefined;
      let canvasRefreshFrame: number | undefined;
      let canvasObserver: ResizeObserver | undefined;
      let observeWebglCanvas: (() => void) | undefined;
      const rendererStats = {
        kind: "dom" as "webgl" | "dom",
        contextLosses: 0,
        enableFailures: 0,
        canvasMismatches: 0,
        canvasResizes: 0,
        lastContextLossAt: null as number | null,
        canvas: null as
          | { width: number; height: number; expectedWidth: number; expectedHeight: number }
          | null,
      };
      // Surfaced in the appearance settings: a silent DOM fallback is the
      // usual culprit when scrolling feels sluggish.
      const publishRenderer = () => {
        rendererStats.kind = webgl ? "webgl" : "dom";
        document.documentElement.dataset.termRenderer = rendererStats.kind;
      };
      const enableWebgl = (retryOnLoss: boolean) => {
        if (disposed) return;
        const generation = ++webglGeneration;
        try {
          const addon = new WebglAddon();
          addon.onContextLoss(() => {
            // A delayed loss event from a disposed addon must not tear down a
            // newer renderer that was installed during recovery.
            recoverOwnedWebglContext(generation, webglGeneration, () => {
              // GPU reset / OOM kill: drop to the DOM renderer right away so
              // the terminal never sits on a dead black canvas, then try WebGL
              // once more — the GPU process is usually back within seconds.
              rendererStats.contextLosses += 1;
              rendererStats.lastContextLossAt = window.performance.now();
              webglGeneration += 1;
              canvasObserver?.disconnect();
              addon.dispose();
              webgl = undefined;
              publishRenderer();
              term.refresh(0, term.rows - 1);
              if (retryOnLoss) {
                webglRetryTimer = window.setTimeout(() => enableWebgl(false), 3_000);
              }
            });
          });
          term.loadAddon(addon);
          webgl = addon;
          // The helper is initialized below, after xterm has opened its
          // renderer internals. Queue the bind so retries observe the newly
          // created canvas rather than the disposed renderer's old node.
          window.setTimeout(() => {
            if (!disposed) observeWebglCanvas?.();
          }, 0);
        } catch {
          rendererStats.enableFailures += 1;
          webgl = undefined;
        }
        publishRenderer();
      };
      enableWebgl(true);

      const searchAddon = new SearchAddon();
      term.loadAddon(searchAddon);
      searchRef.current = searchAddon;
      termRef.current = term;
      const searchResultsSub = searchAddon.onDidChangeResults((r) => {
        setFindCount({ index: r.resultIndex, count: r.resultCount });
      });

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
        // Ctrl/Cmd+F opens the terminal find box, not the browser's native find
        // (blind to WebGL cells) or readline's forward-char. Shift/Alt+F is left
        // to the shell.
        if (
          event.type === "keydown" &&
          (isMac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey) &&
          !event.shiftKey &&
          !event.altKey &&
          (event.key === "f" || event.key === "F")
        ) {
          event.preventDefault();
          openFindRef.current();
          return false;
        }
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
        // If a scroll restore is mid-flight it has forced smoothScrollDuration
        // to 0 and writes savedSmooth back when it finishes — update THAT, or
        // its cleanup would silently revert this preference change.
        const smoothMs = next.smoothScroll ? SMOOTH_SCROLL_MS : 0;
        if (restoreDepth > 0) savedSmooth = smoothMs;
        else term.options.smoothScrollDuration = smoothMs;
        term.options.scrollSensitivity = next.scrollSensitivity;
        // Font metrics changed — refit/re-scale via the shared path.
        window.setTimeout(() => relayout(true), 0);
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
          rendererStats.canvas = {
            width: canvas.width,
            height: canvas.height,
            expectedWidth: device.width,
            expectedHeight: device.height,
          };
          if (canvas.width !== device.width || canvas.height !== device.height) {
            rendererStats.canvasMismatches += 1;
            rendererStats.canvasResizes += 1;
            // Do not assign canvas.width/height here. That clears the drawing
            // buffer without notifying WebglRenderer's glyph/rectangle layers
            // and can leave normalized atlas coordinates pointing at stale
            // texture dimensions (garbled glyphs and wrong colors). Ask the
            // addon renderer to run its complete resize path instead.
            const rendererApi = (
              webgl as unknown as {
                _renderer?: { handleResize?: (cols: number, rows: number) => void };
              }
            )._renderer;
            let repaired = false;
            try {
              if (rendererApi?.handleResize) {
                rendererApi.handleResize(term.cols, term.rows);
                repaired = true;
              }
            } catch {
              // A renderer from a mismatched addon build can throw while its
              // atlas is being rebuilt. Fall back cleanly instead of leaving
              // a half-resized WebGL canvas active.
            }
            if (!repaired) {
              // Older addon builds expose no resize hook. Drop to xterm's DOM
              // renderer rather than mutate a live WebGL drawing buffer.
              rendererStats.enableFailures += 1;
              webglGeneration += 1;
              canvasObserver?.disconnect();
              try {
                webgl.dispose();
              } catch {
                // The terminal's own disposal path will finish releasing it.
              }
              webgl = undefined;
              publishRenderer();
            }
            rendererStats.canvas = {
              width: canvas.width,
              height: canvas.height,
              expectedWidth: device.width,
              expectedHeight: device.height,
            };
            // The resize path clears the drawing buffer. Let xterm's own
            // observer finish its dimension pass before repainting; an
            // immediate refresh can race the addon's observer and leave a
            // partially populated atlas/canvas for one or more frames.
            if (canvasRefreshFrame == null) {
              canvasRefreshFrame = requestAnimationFrame(() => {
                canvasRefreshFrame = undefined;
                if (!disposed) term.refresh(0, term.rows - 1);
              });
            }
          }
        } catch {
          // Private xterm internals moved — the addon then keeps sizing
          // itself, which is correct everywhere except emulated-DPR contexts.
        }
      };
      // The addon's own observer can overwrite the fix on any layout change;
      // watch its canvas and re-correct right after (created later than the
      // addon's observer, so it runs after it).
      observeWebglCanvas = () => {
        canvasObserver?.disconnect();
        canvasObserver = undefined;
        if (!webgl) return;
        const canvas = (
          term as unknown as {
            _core?: { _renderService?: { _renderer?: { value?: { _canvas?: HTMLCanvasElement } } } };
          }
        )._core?._renderService?._renderer?.value?._canvas;
        if (canvas) {
          canvasObserver = new ResizeObserver(() => syncWebglCanvas());
          canvasObserver.observe(canvas);
        }
      };
      observeWebglCanvas();

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
      const lazyHistory = createLazyHistory();
      const hiddenOutput = createHiddenOutputBuffer(HIDDEN_OUTPUT_LIMIT);
      let viewerVisible = visibleRef.current && document.visibilityState === "visible";

      const requestHistory = (intent: HistoryIntent) => {
        if (!lazyHistory.request(intent)) return false;
        // History loading is an explicit repaint: cover the terminal while
        // the larger scrollback snapshot replaces its buffer.
        gate.waitForReplay();
        beginReplay("reset");
        phxChannel.push("load_history", {});
        return true;
      };
      loadHistoryRef.current = requestHistory;

      // See streamGate.ts for the replay/dedup/input-guard invariants.
      const gate = createStreamGate();
      // Optional mosh-style local echo (appearance setting).
      const typeahead = createTypeahead(term, () => livePrefs.localEcho);

      // Flow control: acknowledge bytes once xterm has PARSED them, so the
      // server can bound the in-flight backlog per client (and skip-to-
      // repaint on slow links). Counting parsed bytes — not received ones —
      // also covers renderer backpressure.
      type ReplayTrace = {
        trigger: ReplayTrigger;
        presentation: ReplayPresentation;
        startedAt: number;
        firstBatchAt: number | null;
        completedAt: number | null;
      };
      const flowStats: {
        acked: number;
        resets: number;
        renderer: typeof rendererStats;
        replay: ReplayTrace | null;
        replayHistory: ReplayTrace[];
      } = {
        acked: 0,
        resets: 0,
        renderer: rendererStats,
        replay: null,
        replayHistory: [],
      };
      // Keep trace ownership aligned with the wire replay, not merely with
      // the latest UI request. A new replay can start while xterm is still
      // parsing the tail of an older multi-batch replay.
      let wireReplayTrace: ReplayTrace | null = null;
      flowStatsRef.current = flowStats;
      const debugWindow = window as unknown as Record<string, unknown>;
      if (debugHandle) {
        const debugTerms =
          (debugWindow.__dalaTerms as Record<string, unknown> | undefined) ??
          (debugWindow.__dalaTerms = {} as Record<string, unknown>);
        debugTerms[sessionId] = term;
      }
      function beginReplay(trigger: ReplayTrigger) {
        const presentation = replayPresentation(trigger, hasRenderedFrameRef.current);
        replayTriggerRef.current = trigger;
        replayPresentationRef.current = presentation;
        const trace: ReplayTrace = {
          trigger,
          presentation,
          startedAt: window.performance.now(),
          firstBatchAt: null,
          completedAt: null,
        };
        flowStats.replay = trace;
        flowStats.replayHistory.push(trace);
        // The debug trace is intentionally available to e2e diagnostics, but
        // it must not become a per-session append-only allocation. Keep the
        // most recent transitions; production behavior never depends on the
        // history itself.
        if (flowStats.replayHistory.length > 32) flowStats.replayHistory.shift();
        // Keep the settled frame visible for warm catch-up/flow replays. A
        // cold attach or explicit reset must remain covered until complete.
        if (presentation === "cover") setReplaying(true);
      }
      // The first replay starts as soon as the channel is ready. Recording it
      // here gives e2e tests a stable cold-attach event even when the server
      // returns an empty snapshot.
      beginReplay("initial");
      // Debug/e2e handle: WebGL leaves no text in the DOM, so tests read the
      // emulator buffer through this instead of scraping HTML. Only the main
      // session view (debugHandle) binds it — see the Props doc.
      if (debugHandle && visibleRef.current) {
        debugWindow.__dalaTerm = term;
        debugWindow.__dalaFlow = flowStats;
      }
      let ackChannelJoined = false;
      const ackCounter = createAckCounter((bytes, alt) => {
        // Phoenix queues pushes made while disconnected. An ack belongs only
        // to the Channel generation whose bytes produced it; never carry an
        // old ledger tail into the replacement server-side Channel process.
        const joined = (phxChannel as unknown as { isJoined(): boolean }).isJoined();
        if (!ackChannelJoined || !joined) return;
        flowStats.acked += bytes;
        phxChannel.push("ack", { bytes, alt });
      });
      const invalidateAckEpoch = () => {
        ackChannelJoined = false;
        ackCounter.reset();
      };
      phxChannel.onError(invalidateAckEpoch);
      phxChannel.onClose(invalidateAckEpoch);
      // A width change can trigger several ResizeObserver passes, while an
      // inline TUI may redraw only after handling SIGWINCH. If the viewport was
      // at the bottom, keep that intent across both phases: otherwise a second
      // pass can capture xterm's transient post-reflow position as if the user
      // had scrolled there. The short window is refreshed by consecutive
      // resizes and every parsed TUI redraw lands back at the bottom.
      const BOTTOM_PIN_MS = 350;
      let bottomPinUntil = 0;
      let bottomPinTimer: number | undefined;
      let bottomPinFrame: number | undefined;
      const bottomPinActive = () => window.performance.now() < bottomPinUntil;
      const scrollPinnedBottom = () => {
        if (!disposed && bottomPinActive()) term.scrollToBottom();
      };
      const preserveBottomAfterResize = () => {
        bottomPinUntil = window.performance.now() + BOTTOM_PIN_MS;
        window.clearTimeout(bottomPinTimer);
        if (bottomPinFrame != null) cancelAnimationFrame(bottomPinFrame);
        term.scrollToBottom();
        bottomPinFrame = requestAnimationFrame(() => {
          scrollPinnedBottom();
          bottomPinFrame = requestAnimationFrame(scrollPinnedBottom);
        });
        bottomPinTimer = window.setTimeout(() => {
          if (!disposed) term.scrollToBottom();
          bottomPinUntil = 0;
        }, BOTTOM_PIN_MS);
      };
      const writeCounted = (
        data: Uint8Array | string,
        done?: () => void,
        pinScroll = true,
      ) => {
        const size = typeof data === "string" ? data.length : data.byteLength;
        const ackEpoch = ackCounter.epoch();
        term.write(data, () => {
          ackCounter.consumed(size, term.buffer.active.type === "alternate", ackEpoch);
          if (pinScroll) scrollPinnedBottom();
          done?.();
        });
      };

      visibilityActionRef.current = (nextVisible) => {
        if (viewerVisible === nextVisible) return;
        viewerVisible = nextVisible;
        phxChannel.push("visibility", { visible: nextVisible });
        if (!nextVisible) return;
        if (debugHandle) {
          debugWindow.__dalaFlow = flowStats;
        }

        if (hiddenOutput.isDirty()) {
          // The server's screen-only repaint is a barrier over all output
          // already in flight. Hold deltas until its first replay batch; the
          // snapshot supersedes them, so parsing them into the old emulator
          // would create a transient frame and waste renderer work.
          gate.waitForReplay();
          beginReplay("catch-up");
          phxChannel.push("catch_up", {});
          return;
        }

        const pending = hiddenOutput.drain();
        if (pending.byteLength > 0) {
          writeCounted(typeahead.reconcile(pending));
        }
      };

      const refs = onTerminalChannelMessages(channel, {
        replay: (payload) => {
          // reset flag = mid-session flow-control snapshot: treat it as a
          // fresh join so the screen clears and the seq baseline moves.
          if (payload.reset) {
            gate.joined();
            flowStats.resets += 1;
          }
          const data = payload.data ? base64ToBytes(payload.data) : "";
          const { reset, release, generation, firstBatch } = gate.replayBatch(
            payload.seq,
            payload.done,
            payload.reset,
          );
          if (reset) {
            // Flow-control repaints arrive without a client-side trigger.
            // Once a frame has been rendered, classify those as warm flow
            // replays so the old frame remains visible during parsing. A
            // catch-up/history/reset request already selected its trigger.
            const trigger =
              replayTriggerRef.current === "initial" && hasRenderedFrameRef.current
                ? "flow"
                : replayTriggerRef.current;
            if (
              flowStats.replay == null ||
              flowStats.replay.completedAt != null ||
              flowStats.replay.firstBatchAt != null ||
              flowStats.replay.trigger !== trigger
            ) {
              beginReplay(trigger);
            } else {
              replayPresentationRef.current = replayPresentation(
                trigger,
                hasRenderedFrameRef.current,
              );
              if (replayPresentationRef.current === "cover") setReplaying(true);
            }
            const plan = replayBatchPlan(
              replayPresentationRef.current,
              reset,
              payload.done,
              data,
            );
            replayPresentationRef.current = plan.presentation;
            if (flowStats.replay) flowStats.replay.presentation = plan.presentation;
            if (plan.presentation === "cover") setReplaying(true);
            typeahead.abandon();
            ackCounter.consumed(
              hiddenOutput.byteLength(),
              term.buffer.active.type === "alternate",
            );
            hiddenOutput.reset();
            // A holder snapshot starts with in-band RIS. Let xterm process it
            // in write order so a warm frame is not synchronously cleared one
            // macrotask before the replacement bytes are parsed.
            if (plan.resetBeforeWrite) term.reset();
          }

          if (firstBatch) wireReplayTrace = flowStats.replay;
          const replayTrace = wireReplayTrace;
          if (replayTrace && replayTrace.firstBatchAt == null) {
            replayTrace.firstBatchAt = window.performance.now();
          }
          const discardHiddenOutput = shouldDiscardHiddenOutput(
            replayTrace?.trigger ?? "initial",
            payload.reset,
            payload.data === "",
          );
          if (release) wireReplayTrace = null;
          if (release) {
            writeCounted(data, () => {
              // xterm parses writes asynchronously. A newer replay can start
              // after this batch is queued but before this callback runs; in
              // that case only its byte acknowledgement is still relevant.
              if (!gate.replayParsed(generation)) return;
              term.scrollToBottom();
              hasRenderedFrameRef.current = true;
              if (replayTrace) {
                replayTrace.completedAt = window.performance.now();
              }
              setReplaying(false);
              // An unmarked reset after this point is a flow repaint; leave
              // the trigger ref in the initial state so the next reset is
              // inferred from hasRenderedFrameRef rather than stale intent.
              replayTriggerRef.current = "initial";
              replayPresentationRef.current = "cover";
              if (discardHiddenOutput) {
                // A timeout fallback preserves the old frame and carries no
                // authoritative snapshot. Drop bytes buffered while hidden,
                // but acknowledge them so the server's flow ledger converges.
                const hiddenBytes = hiddenOutput.byteLength();
                if (hiddenBytes > 0) {
                  ackCounter.consumed(
                    hiddenBytes,
                    term.buffer.active.type === "alternate",
                  );
                }
                hiddenOutput.reset();
              }
              const intent = lazyHistory.finishReplay(payload.historyLoaded, payload.retrying);
              if (intent === "scroll") term.scrollLines(-term.rows);
              if (intent === "find" && findQueryRef.current) {
                runFind(1, findQueryRef.current, true);
              }
            }, false);
          } else {
            // Replay scrolling is settled only by the current generation's
            // final callback. An older batch may finish parsing after a newer
            // replay starts and must have no scroll side effects.
            writeCounted(data, undefined, false);
          }
        },
        output: (payload) => {
          const data = base64ToBytes(payload.data);
          if (!gate.acceptOutput(payload.seq)) {
            // Every received frame was counted by the channel. This includes
            // output discarded behind a pending snapshot and a duplicate that
            // arrives after the snapshot already established its seq baseline.
            // Ack both so the sent-minus-acked ledger cannot drift upward and
            // trigger a redundant skip/repaint cycle.
            ackCounter.consumed(data.byteLength, term.buffer.active.type === "alternate");
            return;
          }
          if (!viewerVisible) {
            const buffered = hiddenOutput.push(data);
            ackCounter.consumed(buffered.droppedBytes, term.buffer.active.type === "alternate");
            return;
          }
          writeCounted(typeahead.reconcile(data));
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
      // Preserve the scroll position across a reflow. A width change (a side
      // panel toggling) re-wraps the scrollback; xterm only keeps the viewport
      // pinned when it sat at the BOTTOM, so a viewport parked mid-scrollback
      // lands on a different line (the jump the user sees). There is no clean
      // xterm API for this (even VS Code punts) — so we heuristically re-anchor:
      //  * measure the top line as a count of LOGICAL lines from the BOTTOM
      //    (survives scrollback trimming, unlike an absolute index or a marker,
      //    which the reflow's direct array writes don't update);
      //  * re-apply AFTER the reflow's own scroll-sync runs. xterm's Viewport
      //    queues a `_sync()` on the next frame that force-writes scrollTop back
      //    to `ydisp*cellHeight`, so a scroll issued during/before it is undone.
      //    Defer past that frame and verify/retry until it sticks.
      // Anchor = the top logical line's TEXT, its position as a count of LOGICAL
      // lines from the BOTTOM, and the wrapped-row OFFSET into that line. Text is
      // what survives a re-wrap (indices churn, markers don't track reflow); the
      // from-bottom count (trim-robust) DISAMBIGUATES a repeated line — TUI
      // borders, `───` separators, prompts — so we re-anchor to the copy nearest
      // where the viewport was, not the first (topmost) one; the offset keeps a
      // viewport parked mid-way through a tall wrapped line from jumping up.
      type ScrollAnchor = { text: string | null; fromBottom: number; offset: number };
      // A logical line's text built WITHOUT per-row trimming (only the final
      // padding is dropped): translateToString(true) trims each wrapped row, so
      // an interior space landing on a moved wrap column would silently change
      // the string across a re-wrap. translateToString(false) keeps every cell.
      const logicalTextAt = (start: number): string => {
        const buf = term.buffer.active;
        let text = buf.getLine(start)?.translateToString(false) ?? "";
        for (let i = start + 1; i < buf.length; i++) {
          if (!buf.getLine(i)?.isWrapped) break;
          text += buf.getLine(i)?.translateToString(false) ?? "";
        }
        return text.replace(/\s+$/, "");
      };
      // Rows a logical line occupies (its wrapped height) at the current width.
      const lineRows = (start: number): number => {
        const buf = term.buffer.active;
        let end = start + 1;
        while (end < buf.length && buf.getLine(end)?.isWrapped) end++;
        return end - start;
      };
      const captureAnchor = (): ScrollAnchor | null => {
        const buf = term.buffer.active;
        if (buf.viewportY >= buf.baseY) return null; // bottom uses the short pin above
        let top = buf.viewportY;
        while (top > 0 && buf.getLine(top)?.isWrapped) top--;
        const offset = buf.viewportY - top; // which wrapped row within the line
        let fromBottom = 0;
        for (let i = top; i < buf.length; i++) {
          if (!buf.getLine(i)?.isWrapped) fromBottom++;
        }
        const text = logicalTextAt(top);
        return { text: text.trim().length > 0 ? text : null, fromBottom, offset };
      };
      const rowAtFromBottom = (fromBottom: number): number => {
        const buf = term.buffer.active;
        let count = 0;
        for (let i = buf.length - 1; i >= 0; i--) {
          if (buf.getLine(i)?.isWrapped) continue;
          if (++count === fromBottom) return i;
        }
        return 0;
      };
      // Nearest logical line whose text matches the anchor is the target's start.
      // Search is BOUNDED to a window around the position estimate: it keeps a
      // 10k+ line scrollback from being fully rescanned, resolves repeats to the
      // right region, and (because output appended during the deferred restore
      // only shifts the estimate by a few lines) tolerates concurrent output.
      const resolveTarget = (anchor: ScrollAnchor): number => {
        const buf = term.buffer.active;
        const estimate = rowAtFromBottom(anchor.fromBottom);
        let logicalStart = estimate;
        if (anchor.text != null) {
          const WINDOW = 500; // rows either side of the estimate
          const lo = Math.max(0, estimate - WINDOW);
          const hi = Math.min(buf.length, estimate + WINDOW);
          let best = -1;
          let bestDist = Infinity;
          for (let i = lo; i < hi; i++) {
            const line = buf.getLine(i);
            if (!line || line.isWrapped) continue; // logical starts only
            if (logicalTextAt(i) === anchor.text) {
              const dist = Math.abs(i - estimate);
              if (dist < bestDist) {
                bestDist = dist;
                best = i;
              }
            }
          }
          if (best >= 0) logicalStart = best;
        }
        // Re-add the intra-line offset, clamped to the line's new wrapped height.
        const clamped = Math.min(anchor.offset, Math.max(0, lineRows(logicalStart) - 1));
        return logicalStart + clamped;
      };
      // A single width change can fire maybeResize more than once, so restores
      // can overlap. Save the user's smooth-scroll setting on the FIRST active
      // restore and put it back only when the LAST one finishes — otherwise a
      // nested restore's cleanup could leave it stuck at 0.
      let restoreDepth = 0;
      let savedSmooth = 0;
      const restoreScroll = (anchor: ScrollAnchor) => {
        if (restoreDepth === 0) savedSmooth = term.options.smoothScrollDuration ?? 0;
        restoreDepth++;
        term.options.smoothScrollDuration = 0; // jump, don't animate the re-anchor
        let tries = 4;
        let target = -1; // resolved ONCE (see below), reused across retries
        const done = () => {
          if (--restoreDepth === 0 && !disposed) {
            term.options.smoothScrollDuration = savedSmooth;
          }
        };
        const attempt = () => {
          if (disposed) return done();
          // Resolve on the first attempt only: the buffer is stable post-reflow
          // and re-resolving each retry would CHASE any concurrent output (the
          // target would keep moving and the verify never converge) and rescan
          // the buffer needlessly.
          if (target < 0) target = resolveTarget(anchor);
          term.scrollToLine(target);
          requestAnimationFrame(() => {
            if (disposed) return done();
            // xterm's post-resize `_sync()` can force scrollTop back to the old
            // ydisp; re-apply until the viewport actually lands on the anchor.
            if (term.buffer.active.viewportY !== target && --tries > 0) attempt();
            else done();
          });
        };
        // First frame lets xterm's post-resize `_sync()` run, then we scroll.
        requestAnimationFrame(attempt);
      };

      let lastSize = "";
      let lastLayoutBox = "";
      const currentLayoutBox = () =>
        `${container.clientWidth}x${container.clientHeight}@${window.devicePixelRatio}`;
      const maybeResize = () => {
        if (disposed) return;
        const buf = term.buffer.active;
        const stayAtBottom = bottomPinActive() || buf.viewportY >= buf.baseY;
        const anchor = stayAtBottom ? null : captureAnchor();
        resetPadding();
        fit.fit();
        clampOverflow();
        centerPadding();
        syncWebglCanvas();
        const key = term.rows + "x" + term.cols;
        if (key !== lastSize) {
          lastSize = key;
          if (stayAtBottom) preserveBottomAfterResize();
          pushResize();
          if (anchor != null) restoreScroll(anchor);
        }
      };
      // Timer/observer entry point that respects the current size role.
      const relayout = (force = false) => {
        if (disposed) return;
        const layoutBox = currentLayoutBox();
        if (!force && layoutBox === lastLayoutBox) return;
        lastLayoutBox = layoutBox;
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
        // A promoted follower keeps its full scrollback, so it can be scrolled
        // up — this fit() rewraps to our own width just like a panel toggle, so
        // preserve the viewport across it (this path used to jump silently).
        const anchor = captureAnchor();
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
        if (anchor != null && term.cols !== prevCols) restoreScroll(anchor);
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
        lastLayoutBox = currentLayoutBox();
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
          const buf = term.buffer.active;
          const stayAtBottom = bottomPinActive() || buf.viewportY >= buf.baseY;
          const anchor = stayAtBottom ? null : captureAnchor();
          resetPadding();
          fit.fit();
          clampOverflow();
          centerPadding();
          syncWebglCanvas();
          if (stayAtBottom) preserveBottomAfterResize();
          pushResize();
          if (anchor != null) restoreScroll(anchor);
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
        // Keep the settled frame in place until the holder confirms the
        // reset. If the request times out, the empty non-reset fallback can
        // then reveal the old frame instead of exposing a blank terminal.
        gate.waitForReplay();
        beginReplay("reset");
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
      localActionsRef.current = { reset, refit, focus: () => term.focus(), sendText, sendKey };
      if (actionsRef && visibleRef.current) actionsRef.current = localActionsRef.current;
      relayoutRef.current = relayout;

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
            platform?: "windows" | "macos" | "linux";
          }) => {
            // Every successful (re)join creates a fresh server-side Channel
            // ledger. Rotate before any replay write callback can acknowledge
            // bytes from the prior transport.
            ackCounter.reset();
            ackChannelJoined = true;
            gate.joined();
            // A successful rejoin abandons any truncated wire replay from the
            // previous transport. Its trace must not own the replacement
            // connection's first batch or carry a stale explicit trigger.
            wireReplayTrace = null;
            replayTriggerRef.current = "initial";
            if (resp?.platform) onPlatform?.(resp.platform);
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
              // Report the settled viewport; the server resizes the PTY
              // first and only then renders the attach repaint, so its soft
              // wraps match this exact width.
              phxChannel.push("attach", { rows: term.rows, cols: term.cols });
              lastSize = term.rows + "x" + term.cols;
              // Layout/fonts may still be settling right after join/refresh;
              // re-fit on the next ticks so early output is not at a stale
              // size.
              window.setTimeout(() => relayout(true), 120);
              window.setTimeout(() => relayout(true), 600);
            }
            // Attach first: otherwise this new viewer looks like an existing
            // client during its initial resize and can trigger an unnecessary
            // full-history repaint ahead of the viewport-only repaint.
            phxChannel.push("visibility", { visible: viewerVisible });
          },
        )
        .receive("error", () => {
          term.writeln("\x1b[31mcould not attach to session\x1b[0m", () => {
            if (!disposed) setReplaying(false);
          });
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
        if (uploadAbortRef.current) return;
        const controller = new AbortController();
        uploadAbortRef.current = controller;

        try {
          const paths = await uploadPastedFiles(
            files,
            (message) => errorRef.current?.(message),
            {
              signal: controller.signal,
              onProgress: (progress) => {
                if (!disposed) setUploadProgress(progress);
              },
            },
          );
          if (paths.length > 0 && !disposed) {
            term.paste(pastedPathsText(paths));
            term.focus();
          }
        } finally {
          if (uploadAbortRef.current === controller) uploadAbortRef.current = null;
          if (!disposed) setUploadProgress(null);
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
      const onHistoryWheel = (event: WheelEvent) => {
        if (event.deltaY >= 0 || scrollRoute() !== "lines" || lazyHistory.isLoaded()) return;
        requestHistory("scroll");
        event.preventDefault();
        event.stopPropagation();
      };
      container.addEventListener("wheel", onHistoryWheel, { capture: true, passive: false });
      const applyPanLines = (lines: number, clientX: number, clientY: number) => {
        if (lines === 0) return;
        if (scrollRoute() === "lines") {
          if (lines < 0 && !lazyHistory.isLoaded()) {
            requestHistory("scroll");
            return;
          }
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

      // Idle self-heal: compare the layout fingerprint periodically. The old
      // unconditional fit repainted the WebGL canvas every 2.5s even when
      // nothing moved, which caused rare full-terminal flashes.
      const idleTimer = window.setInterval(relayout, 2500);

      // Extra triggers a ResizeObserver can miss: window resize, browser zoom
      // (via window resize on most browsers), and the tab becoming visible.
      const onWindowResize = () => relayout();
      const onVisibilityChange = () => {
        const pageVisible = document.visibilityState === "visible";
        visibilityActionRef.current(visibleRef.current && pageVisible);
        if (pageVisible) relayout(true);
      };
      window.addEventListener("resize", onWindowResize);
      document.addEventListener("visibilitychange", onVisibilityChange);

      cleanup = () => {
        if (actionsRef && actionsRef.current === localActionsRef.current) actionsRef.current = null;
        localActionsRef.current = null;
        relayoutRef.current = null;
        visibilityActionRef.current = () => {};
        loadHistoryRef.current = () => false;
        // Only drop the debug handle when it is still OURS — a newer view
        // (session switch) may have rebound it already.
        const w = window as unknown as Record<string, unknown>;
        if (w.__dalaTerm === term) delete w.__dalaTerm;
        if (w.__dalaFlow === flowStats) delete w.__dalaFlow;
        if (flowStatsRef.current === flowStats) flowStatsRef.current = null;
        if (w.__dalaTerms && typeof w.__dalaTerms === "object") {
          delete (w.__dalaTerms as Record<string, unknown>)[sessionId];
        }
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
        container.removeEventListener("wheel", onHistoryWheel, true);
        observer.disconnect();
        canvasObserver?.disconnect();
        window.clearTimeout(resizeTimer);
        window.clearTimeout(webglRetryTimer);
        webglGeneration += 1;
        if (canvasRefreshFrame != null) cancelAnimationFrame(canvasRefreshFrame);
        window.clearTimeout(bottomPinTimer);
        if (bottomPinFrame != null) cancelAnimationFrame(bottomPinFrame);
        window.clearInterval(idleTimer);
        window.removeEventListener("resize", onWindowResize);
        document.removeEventListener("visibilitychange", onVisibilityChange);
        container.removeEventListener("mouseup", onMouseUp);
        stopPrefsSync();
        stopThemeSync();
        inputDisposable.dispose();
        typeahead.dispose();
        ackCounter.dispose();
        searchResultsSub.dispose();
        searchRef.current = null;
        termRef.current = null;
        unsubscribeTerminalChannel(channel, refs);
        phxChannel.leave();
        term.dispose();
      };
    });

    return () => {
      disposed = true;
      uploadAbortRef.current?.abort();
      uploadAbortRef.current = null;
      cleanup?.();
    };
  }, [sessionId]);

  // Pooled visibility: on reveal, this instance claims the shared action/
  // debug handles, re-checks layout (a window resize may have landed while
  // hidden) and takes focus; hiding releases the claims to the next view.
  useLayoutEffect(() => {
    visibilityActionRef.current(visible && document.visibilityState === "visible");
    if (!visible) return;
    if (actionsRef && localActionsRef.current) actionsRef.current = localActionsRef.current;
    if (debugHandle && termRef.current) {
      (window as unknown as Record<string, unknown>).__dalaTerm = termRef.current;
      if (flowStatsRef.current) {
        (window as unknown as Record<string, unknown>).__dalaFlow = flowStatsRef.current;
      }
    }
    relayoutRef.current?.(true);
    termRef.current?.focus();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visible]);

  return (
    <div
      className="relative h-full w-full [contain:layout_paint]"
      data-replay-state={replaying ? "cover" : "ready"}
    >
      {/* Padding lives on .xterm (app.css), NOT here: the fit addon takes
          the parent's computed border-box height and only subtracts the
          terminal element's own padding — parent padding makes it overshoot
          by a row and TUI bottom bars get clipped. */}
      <div ref={containerRef} className="h-full w-full" />
      {uploadProgress && (
        <UploadProgressView
          progress={uploadProgress}
          onCancel={() => uploadAbortRef.current?.abort()}
          cancelLabel={t("cancel")}
          className="absolute bottom-3 left-1/2 z-30 w-[min(28rem,calc(100%_-_1.5rem))] -translate-x-1/2 rounded-md border border-line bg-bg1/95 px-3 py-2 shadow-xl shadow-black/40 backdrop-blur-sm"
        />
      )}
      {findOpen && (
        <div
          id="terminal-find"
          className="absolute right-3 top-2 z-20 flex items-center gap-1 rounded-lg border border-line bg-bg1/95 py-1 pl-2.5 pr-1 shadow-xl shadow-black/30 backdrop-blur-sm"
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              e.preventDefault();
              closeFind();
            } else if (e.key === "Enter") {
              e.preventDefault();
              runFind(e.shiftKey ? -1 : 1, findQuery);
            }
          }}
        >
          <input
            ref={findInputRef}
            id="terminal-find-input"
            value={findQuery}
            onChange={(e) => {
              setFindQuery(e.target.value);
              runFind(1, e.target.value, true);
            }}
            placeholder={t("findPlaceholder")}
            autoFocus
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
            className="w-36 min-w-0 bg-transparent font-mono text-[12px] text-fg outline-none placeholder:text-fg-muted/60"
          />
          <span className="shrink-0 whitespace-nowrap px-1 font-mono text-[10px] tabular-nums text-fg-muted/70">
            {findQuery === ""
              ? ""
              : findCount.count === 0
                ? t("findNoResults")
                : `${findCount.index + 1}/${findCount.count}`}
          </span>
          <button
            id="terminal-find-prev"
            aria-label={t("findPrev")}
            onClick={() => runFind(-1, findQuery)}
            className="grid h-6 w-6 shrink-0 place-items-center rounded font-mono text-[13px] text-fg-muted transition-colors hover:bg-bg2 hover:text-fg"
          >
            ↑
          </button>
          <button
            id="terminal-find-next"
            aria-label={t("findNext")}
            onClick={() => runFind(1, findQuery)}
            className="grid h-6 w-6 shrink-0 place-items-center rounded font-mono text-[13px] text-fg-muted transition-colors hover:bg-bg2 hover:text-fg"
          >
            ↓
          </button>
          <button
            id="terminal-find-close"
            aria-label={t("close")}
            onClick={closeFind}
            className="grid h-6 w-6 shrink-0 place-items-center rounded font-mono text-[13px] text-fg-muted transition-colors hover:bg-bg2 hover:text-fg"
          >
            ×
          </button>
        </div>
      )}
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
        data-replay-cover
        className={`pointer-events-none absolute inset-0 bg-bg0 ${replayCoverTransition(replaying)}`}
      />
    </div>
  );
}
