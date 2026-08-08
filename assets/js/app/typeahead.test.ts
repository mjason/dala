import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Terminal } from "@xterm/xterm";
import {
  AUTO_ECHO_OFF_MS,
  AUTO_ECHO_ON_MS,
  createEchoMeter,
  createTypeahead,
} from "./typeahead";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const bytes = (s: string) => encoder.encode(s);
const text = (u: Uint8Array) => decoder.decode(u);

function makeTerm() {
  const buffer = { type: "normal", cursorX: 10 };
  const writes: string[] = [];
  const stub = {
    cols: 80,
    buffer: { active: buffer },
    write(data: string | Uint8Array) {
      writes.push(typeof data === "string" ? data : decoder.decode(data));
    },
  };
  return { term: stub as unknown as Terminal, writes, buffer };
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("prediction (local echo)", () => {
  it("paints a printable keystroke immediately", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    ta.predict("a");
    expect(writes).toEqual(["a"]);
  });

  it("stays silent when the feature is disabled", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "off");

    ta.predict("a");
    expect(writes).toEqual([]);
    // and reconcile passes output through untouched
    const data = bytes("a");
    expect(ta.reconcile(data)).toBe(data);
  });

  it("stays out of the alternate screen buffer", () => {
    const { term, writes, buffer } = makeTerm();
    buffer.type = "alternate";
    const ta = createTypeahead(term, () => "on");

    ta.predict("a");
    expect(writes).toEqual([]);
  });

  it("ignores control characters and composed (multi-char) input", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    ta.predict("\r");
    ta.predict("\x1b");
    ta.predict("\x7f");
    ta.predict("ab"); // paste / IME commit
    ta.predict(""); // nothing at all
    expect(writes).toEqual([]);
  });

  it("declines near the right edge where soft-wrap makes cursor math ambiguous", () => {
    const { term, writes, buffer } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    buffer.cursorX = 78; // cols - 2
    ta.predict("a");
    expect(writes).toEqual([]);

    buffer.cursorX = 77;
    ta.predict("a");
    expect(writes).toEqual(["a"]);
  });

  it("caps the speculation at 40 unconfirmed keystrokes", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    for (let i = 0; i < 45; i++) ta.predict("x");
    expect(writes).toHaveLength(40);
  });
});

describe("reconciliation with the server echo", () => {
  it("passes output through untouched when nothing is pending", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    const data = bytes("prompt$ ");
    expect(ta.reconcile(data)).toBe(data);
  });

  it("consumes a matching echo by rewinding over the predicted cells", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("l");
    ta.predict("s");

    const out = ta.reconcile(bytes("ls"));
    expect(text(out)).toBe("\x1b[2Dls");

    // fully consumed: the next chunk flows through as-is
    const tail = bytes(" -la");
    expect(ta.reconcile(tail)).toBe(tail);
  });

  it("consumes a partial echo and keeps the remainder pending", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");
    ta.predict("b");
    ta.predict("c");

    expect(text(ta.reconcile(bytes("a")))).toBe("\x1b[1Da");
    expect(text(ta.reconcile(bytes("bc")))).toBe("\x1b[2Dbc");
  });

  it("erases the whole prediction when the echo mismatches", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");
    ta.predict("b");

    const out = ta.reconcile(bytes("xy"));
    expect(text(out)).toBe("\x1b[2D\x1b[Kxy");

    // nothing pending anymore
    const tail = bytes("z");
    expect(ta.reconcile(tail)).toBe(tail);
  });

  it("erases even when the echo matches a prefix but diverges mid-stream", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");
    ta.predict("b");

    // matched=1 but neither the pending nor the data was exhausted
    const out = ta.reconcile(bytes("axz"));
    expect(text(out)).toBe("\x1b[2D\x1b[Kaxz");
  });

  it("never predicts a single non-ASCII character (CJK/accented)", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    for (const ch of ["中", "é", "あ"]) ta.predict(ch);
    expect(writes).toEqual([]);
    // and nothing pending: a later echo must pass through untouched
    const echo = new TextEncoder().encode("x");
    expect(ta.reconcile(echo)).toEqual(echo);
  });

  it("passes binary (non-UTF-8) bytes through byte-for-byte", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    const blob = new Uint8Array([0x00, 0xff, 0xfe, 0x80]);
    expect(ta.reconcile(blob)).toBe(blob);
  });

  it("prefixes the erase sequence to mismatching binary output", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");

    const blob = new Uint8Array([0xff, 0xfe]);
    const out = ta.reconcile(blob);
    const erase = bytes("\x1b[1D\x1b[K");
    expect(Array.from(out)).toEqual([...erase, 0xff, 0xfe]);
  });
});

describe("confirmation timeout", () => {
  it("takes back an unconfirmed prediction after 1s (password prompt)", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("s");
    ta.predict("3");

    vi.advanceTimersByTime(1000);
    expect(writes).toEqual(["s", "3", "\x1b[2D\x1b[K"]);

    // state is clean afterwards
    const data = bytes("ok");
    expect(ta.reconcile(data)).toBe(data);
  });

  it("a matching echo cancels the pending timeout", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");
    ta.reconcile(bytes("a"));

    vi.advanceTimersByTime(5000);
    expect(writes).toEqual(["a"]); // no erase ever written
  });

  it("re-arms the timeout for the unconfirmed remainder after a partial echo", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");
    ta.predict("b");
    ta.reconcile(bytes("a"));

    vi.advanceTimersByTime(1000);
    expect(writes).toEqual(["a", "b", "\x1b[1D\x1b[K"]);
  });
});

describe("TUI guard", () => {
  it("suppresses prediction while a TUI owns the screen, then recovers", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    // cursor addressing + clear: unmistakably a full-screen redraw
    ta.reconcile(bytes("\x1b[H\x1b[2Jredraw"));
    ta.predict("a");
    expect(writes).toEqual([]);

    // quiet window is 500ms
    vi.advanceTimersByTime(500);
    ta.predict("a");
    expect(writes).toEqual(["a"]);
  });

  it("treats alt-screen switching as TUI output", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    ta.reconcile(bytes("\x1b[?1049h"));
    ta.predict("a");
    expect(writes).toEqual([]);
  });

  it("keeps predicting through plain prompt output", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");

    ta.reconcile(bytes("user@host:~$ "));
    ta.predict("a");
    expect(writes).toEqual(["a"]);
  });
});

describe("abandon and dispose", () => {
  it("abandon drops the pending state without touching the screen", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");

    ta.abandon();
    expect(writes).toEqual(["a"]); // nothing erased

    // no stale reconciliation against the dropped prediction
    const data = bytes("x");
    expect(ta.reconcile(data)).toBe(data);

    // and no timeout fires later
    vi.advanceTimersByTime(2000);
    expect(writes).toEqual(["a"]);
  });

  it("dispose cancels the confirmation timer", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "on");
    ta.predict("a");

    ta.dispose();
    vi.advanceTimersByTime(2000);
    expect(writes).toEqual(["a"]);
  });
});

describe("auto mode (echo-latency driven)", () => {
  // A term whose reconcile echoes back what was typed, so a test can play
  // "keystroke → N ms → echo" with the fake clock.
  const roundTrip = (
    ta: ReturnType<typeof createTypeahead>,
    char: string,
    delayMs: number,
  ) => {
    ta.predict(char);
    vi.advanceTimersByTime(delayMs);
    ta.reconcile(bytes(char));
  };

  it("stays inert on a fast link", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "auto");

    for (const char of "abcdef") roundTrip(ta, char, 5);

    expect(writes).toEqual([]); // nothing was ever predicted
    expect(ta.echoDelayMs()).toBeLessThan(AUTO_ECHO_ON_MS);
  });

  it("starts predicting once the echo delay is visible", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "auto");

    // The first sample alone is enough — a 300ms echo needs no averaging.
    roundTrip(ta, "a", 300);
    expect(writes).toEqual([]); // measured, not yet armed for THAT key

    ta.predict("b");
    expect(writes).toEqual(["b"]);
  });

  it("measures without drawing, so a slow link is noticed while inert", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => "auto");

    expect(ta.echoDelayMs()).toBeNull();
    roundTrip(ta, "a", 120);
    expect(ta.echoDelayMs()).toBe(120);
  });

  it("off mode measures nothing and draws nothing", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "off");

    roundTrip(ta, "a", 300);
    expect(writes).toEqual([]);
    expect(ta.echoDelayMs()).toBeNull();
  });
});

describe("createEchoMeter", () => {
  const meterAt = () => {
    let now = 0;
    const meter = createEchoMeter(() => now);
    return { meter, tick: (ms: number) => (now += ms) };
  };

  it("arms on a slow link and disarms only well below the threshold", () => {
    const { meter, tick } = meterAt();

    meter.probe(97);
    tick(200);
    meter.observe(97);
    expect(meter.slowLink()).toBe(true);

    // Hysteresis: samples that merely dip under the arming threshold must
    // not flip prediction off between keystrokes.
    for (let i = 0; i < 6; i++) {
      meter.probe(97);
      tick(AUTO_ECHO_OFF_MS + 10);
      meter.observe(97);
    }
    expect(meter.slowLink()).toBe(true);

    for (let i = 0; i < 20; i++) {
      meter.probe(97);
      tick(2);
      meter.observe(97);
    }
    expect(meter.slowLink()).toBe(false);
  });

  it("ignores output that is not the echo of the probed key", () => {
    const { meter, tick } = meterAt();

    meter.probe(97);
    tick(500);
    meter.observe(120); // some unrelated program output
    expect(meter.averageMs()).toBeNull();

    tick(10);
    meter.observe(97); // the real echo, 510ms after the keystroke
    expect(meter.averageMs()).toBe(510);
  });

  it("never folds an unanswered keystroke into the average", () => {
    const { meter, tick } = meterAt();

    // Password prompt: no echo at all, then output much later.
    meter.probe(97);
    tick(5000);
    meter.observe(97);
    expect(meter.averageMs()).toBeNull();
    expect(meter.slowLink()).toBe(false);

    // And the dead probe does not block the next measurement.
    meter.probe(98);
    tick(80);
    meter.observe(98);
    expect(meter.averageMs()).toBe(80);
  });
});

describe("measuring must not depend on the drawing heuristic", () => {
  // Found by e2e: `auto` never armed against a real shell. The TUI-quiet
  // window fires on any cursor-addressing output — which is exactly what a
  // fancy prompt (oh-my-zsh, powerlevel10k, starship) emits every time it
  // redraws. Each keystroke's echo re-armed the window, the next keystroke
  // landed inside it, and no sample was ever taken: on a 600ms link the user
  // got no local echo and no explanation.
  it("still times the echo while the TUI-quiet window is open", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "auto");

    // A prompt redraw: cursor addressing, so the quiet window is now open.
    ta.reconcile(bytes("\x1b[2K\x1b[1G➜  ~ "));

    ta.predict("a");
    // Nothing drawn — the quiet window still suppresses prediction, correctly.
    expect(writes).toEqual([]);

    vi.advanceTimersByTime(400);
    ta.reconcile(bytes("a"));

    // ...but the delay WAS measured, which is what lets auto arm at all.
    expect(ta.echoDelayMs()).toBe(400);
  });

  it("arms prediction once the quiet window lapses, on the measurement it took", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => "auto");

    ta.reconcile(bytes("\x1b[2K\x1b[1G➜  ~ "));
    ta.predict("a");
    vi.advanceTimersByTime(400);
    ta.reconcile(bytes("a"));
    expect(writes).toEqual([]);

    // Past TUI_QUIET_MS with no further redraw-looking output.
    vi.advanceTimersByTime(600);
    ta.predict("b");
    expect(writes).toEqual(["b"]);
  });
});
