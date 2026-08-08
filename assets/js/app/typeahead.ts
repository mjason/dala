/**
 * mosh/VS Code-style local echo (typeahead): printable keystrokes are drawn
 * immediately instead of waiting a network round-trip; the server's echo is
 * then reconciled against the prediction. Matches are consumed in place
 * (identical cells, no flicker); anything else erases the prediction and
 * defers to the authoritative stream — so TUIs, password prompts and heavy
 * prompt redraws stay correct, at worst with a brief flicker.
 *
 * "auto" is mosh's own policy: the echo delay is measured continuously (a
 * probe costs nothing — it is just a timestamp on a keystroke we are already
 * sending) and prediction switches itself on only once the link is slow
 * enough for the round-trip to be visible. On a local socket it therefore
 * stays completely inert.
 */
import type { Terminal } from "@xterm/xterm";

export type LocalEchoMode = "off" | "auto" | "on";

const CONFIRM_TIMEOUT_MS = 1000;
const MAX_PENDING = 40;

/** Above this measured echo delay "auto" predicts; below the lower bound it
 * stops again. The gap is hysteresis — a link hovering at the threshold must
 * not flip prediction on and off between keystrokes. */
export const AUTO_ECHO_ON_MS = 50;
export const AUTO_ECHO_OFF_MS = 30;
/** Weight of each new sample in the echo-delay average. Low enough that one
 * slow shell (a heavy prompt, a `find /`) cannot arm prediction on its own. */
const ECHO_SMOOTHING = 0.25;
/** A keystroke with no echo by now measured nothing: a password prompt, a
 * TUI that swallowed it, or a stalled link. Never fold it into the average. */
const PROBE_TIMEOUT_MS = 2000;

const encoder = new TextEncoder();

function concat(head: Uint8Array, tail: Uint8Array): Uint8Array {
  const out = new Uint8Array(head.length + tail.length);
  out.set(head, 0);
  out.set(tail, head.length);
  return out;
}

// Cursor-addressing / erase sequences that a plain prompt echo never
// contains, but every TUI redraw (ink, ratatui, …) is full of.
const TUI_OUTPUT = /\x1b\[[0-9;]*[HABCDJKfGd]|\x1b\[\?(?:1049|2026)[hl]/;
const TUI_QUIET_MS = 500;

/**
 * Rolling average of the keystroke → echo delay, plus the on/off decision
 * "auto" mode reads. Split out from the emulator plumbing so the policy is
 * testable without a terminal.
 */
export function createEchoMeter(now: () => number = Date.now) {
  let probeAt: number | null = null;
  let probeCode = -1;
  let averageMs: number | null = null;
  let slow = false;

  return {
    /** Timestamp a keystroke, if no probe is already outstanding. A probe
     * that was never answered (no output came back at all) is replaced
     * rather than blocking every later measurement. */
    probe(code: number) {
      if (probeAt !== null && now() - probeAt <= PROBE_TIMEOUT_MS) return;
      probeAt = now();
      probeCode = code;
    },
    /** First byte of a live output chunk; resolves an outstanding probe. */
    observe(firstByte: number | undefined) {
      if (probeAt === null) return;
      const elapsed = now() - probeAt;
      if (elapsed > PROBE_TIMEOUT_MS) {
        probeAt = null;
        return;
      }
      if (firstByte !== probeCode) return;
      probeAt = null;
      averageMs =
        averageMs === null
          ? elapsed
          : averageMs * (1 - ECHO_SMOOTHING) + elapsed * ECHO_SMOOTHING;
      if (slow) slow = averageMs >= AUTO_ECHO_OFF_MS;
      else slow = averageMs >= AUTO_ECHO_ON_MS;
    },
    /** Should "auto" draw predictions right now? */
    slowLink: () => slow,
    /** Measured echo delay in ms, or null before the first sample. */
    averageMs: () => averageMs,
  };
}

export function createTypeahead(term: Terminal, mode: () => LocalEchoMode) {
  let pending = "";
  let timer: number | undefined;
  let tuiUntil = 0;
  const decoder = new TextDecoder();
  const meter = createEchoMeter();

  const eraseSeq = () => `\x1b[${pending.length}D\x1b[K`;

  const eraseNow = () => {
    if (!pending) return;
    term.write(eraseSeq());
    pending = "";
  };

  const armTimeout = () => {
    window.clearTimeout(timer);
    // No echo showed up (password prompt, stalled link): take it back.
    timer = window.setTimeout(eraseNow, CONFIRM_TIMEOUT_MS);
  };

  // A keystroke whose echo is worth TIMING: one printable ASCII character at
  // a normal prompt, so the first byte of the reply identifies it.
  //
  // Deliberately weaker than `drawable`. Measuring used to require everything
  // drawing requires, and that made "auto" unable to arm for most users: the
  // TUI-quiet heuristic below fires on any cursor-addressing output, which is
  // what EVERY fancy prompt emits when it redraws (oh-my-zsh, powerlevel10k,
  // starship). Each keystroke's echo re-armed the quiet window, the next
  // keystroke landed inside it, no sample was ever taken, and a link that
  // needed local echo never got it. Measurement must not depend on the
  // heuristic that decides whether to draw.
  const measurable = (data: string): boolean => {
    if (term.buffer.active.type !== "normal") return false;
    // Single printable ASCII only. IME/CJK input arrives as composed
    // strings and readline may render it anywhere — leave it to the echo.
    if (data.length !== 1) return false;
    const code = data.charCodeAt(0);
    // > 0x7e: a lone CJK/accented char would echo back as multi-byte
    // UTF-8 (mismatching the char-vs-byte reconcile) and its width-2
    // cell makes the 1-column erase leave half a glyph behind.
    return code >= 0x20 && code <= 0x7e;
  };

  // Everything a prediction additionally needs to be unambiguous.
  const drawable = (): boolean => {
    // A TUI owns the screen right now (Claude Code, opencode, …): its
    // echo is a full redraw, never a plain character — stay out.
    if (Date.now() < tuiUntil) return false;
    if (pending.length >= MAX_PENDING) return false;
    // Soft-wrap at the right edge makes the cursor math ambiguous.
    return term.buffer.active.cursorX < term.cols - 2;
  };

  return {
    /** Call from term.onData BEFORE the keystroke is pushed to the server. */
    predict(data: string) {
      const setting = mode();
      if (setting === "off" || !measurable(data)) return;
      // Probe first and unconditionally: "auto" can only learn that the link
      // got slow from keystrokes it did NOT draw.
      if (!pending) meter.probe(data.charCodeAt(0));
      if (!drawable()) return;
      if (setting === "auto" && !meter.slowLink()) return;
      pending += data;
      term.write(data);
      armTimeout();
    },

    /** Filter live server output; returns the bytes to actually write. */
    reconcile(data: Uint8Array): Uint8Array {
      if (TUI_OUTPUT.test(decoder.decode(data))) {
        tuiUntil = Date.now() + TUI_QUIET_MS;
      }
      meter.observe(data[0]);
      if (!pending) return data;
      let matched = 0;
      while (
        matched < pending.length &&
        matched < data.length &&
        data[matched] === pending.charCodeAt(matched)
      ) {
        matched++;
      }
      window.clearTimeout(timer);
      if (matched > 0 && (matched === pending.length || matched === data.length)) {
        // The echo begins with (a prefix of) our prediction: rewind the
        // cursor so those bytes land on the cells we already painted.
        pending = pending.slice(matched);
        if (pending) armTimeout();
        return concat(encoder.encode(`\x1b[${matched}D`), data);
      }
      // Mismatch: wipe the speculation, then let the truth repaint.
      const erase = encoder.encode(eraseSeq());
      pending = "";
      return concat(erase, data);
    },

    /** Measured keystroke → echo delay (ms), or null before the first sample.
     * Surfaced in the appearance diagnostics so "is the link slow?" is an
     * observation rather than a guess. */
    echoDelayMs: () => meter.averageMs(),

    /** Drop state without touching the screen (replay repaints anyway). */
    abandon() {
      window.clearTimeout(timer);
      pending = "";
    },

    dispose() {
      window.clearTimeout(timer);
    },
  };
}
