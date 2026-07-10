/**
 * mosh/VS Code-style local echo (typeahead): printable keystrokes are drawn
 * immediately instead of waiting a network round-trip; the server's echo is
 * then reconciled against the prediction. Matches are consumed in place
 * (identical cells, no flicker); anything else erases the prediction and
 * defers to the authoritative stream — so TUIs, password prompts and heavy
 * prompt redraws stay correct, at worst with a brief flicker.
 */
import type { Terminal } from "@xterm/xterm";

const CONFIRM_TIMEOUT_MS = 1000;
const MAX_PENDING = 40;

const encoder = new TextEncoder();

function concat(head: Uint8Array, tail: Uint8Array): Uint8Array {
  const out = new Uint8Array(head.length + tail.length);
  out.set(head, 0);
  out.set(tail, head.length);
  return out;
}

export function createTypeahead(term: Terminal, enabled: () => boolean) {
  let pending = "";
  let timer: number | undefined;

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

  return {
    /** Call from term.onData BEFORE the keystroke is pushed to the server. */
    predict(data: string) {
      if (!enabled() || term.buffer.active.type !== "normal") return;
      if (pending.length >= MAX_PENDING) return;
      // Single printable ASCII only. IME/CJK input arrives as composed
      // strings and readline may render it anywhere — leave it to the echo.
      if (data.length !== 1) return;
      const code = data.charCodeAt(0);
      if (code < 0x20 || code === 0x7f) return;
      // Soft-wrap at the right edge makes the cursor math ambiguous.
      if (term.buffer.active.cursorX >= term.cols - 2) return;
      pending += data;
      term.write(data);
      armTimeout();
    },

    /** Filter live server output; returns the bytes to actually write. */
    reconcile(data: Uint8Array): Uint8Array {
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
