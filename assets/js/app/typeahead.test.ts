import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Terminal } from "@xterm/xterm";
import { createTypeahead } from "./typeahead";

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
    const ta = createTypeahead(term, () => true);

    ta.predict("a");
    expect(writes).toEqual(["a"]);
  });

  it("stays silent when the feature is disabled", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => false);

    ta.predict("a");
    expect(writes).toEqual([]);
    // and reconcile passes output through untouched
    const data = bytes("a");
    expect(ta.reconcile(data)).toBe(data);
  });

  it("stays out of the alternate screen buffer", () => {
    const { term, writes, buffer } = makeTerm();
    buffer.type = "alternate";
    const ta = createTypeahead(term, () => true);

    ta.predict("a");
    expect(writes).toEqual([]);
  });

  it("ignores control characters and composed (multi-char) input", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => true);

    ta.predict("\r");
    ta.predict("\x1b");
    ta.predict("\x7f");
    ta.predict("ab"); // paste / IME commit
    ta.predict(""); // nothing at all
    expect(writes).toEqual([]);
  });

  it("declines near the right edge where soft-wrap makes cursor math ambiguous", () => {
    const { term, writes, buffer } = makeTerm();
    const ta = createTypeahead(term, () => true);

    buffer.cursorX = 78; // cols - 2
    ta.predict("a");
    expect(writes).toEqual([]);

    buffer.cursorX = 77;
    ta.predict("a");
    expect(writes).toEqual(["a"]);
  });

  it("caps the speculation at 40 unconfirmed keystrokes", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => true);

    for (let i = 0; i < 45; i++) ta.predict("x");
    expect(writes).toHaveLength(40);
  });
});

describe("reconciliation with the server echo", () => {
  it("passes output through untouched when nothing is pending", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => true);

    const data = bytes("prompt$ ");
    expect(ta.reconcile(data)).toBe(data);
  });

  it("consumes a matching echo by rewinding over the predicted cells", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => true);
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
    const ta = createTypeahead(term, () => true);
    ta.predict("a");
    ta.predict("b");
    ta.predict("c");

    expect(text(ta.reconcile(bytes("a")))).toBe("\x1b[1Da");
    expect(text(ta.reconcile(bytes("bc")))).toBe("\x1b[2Dbc");
  });

  it("erases the whole prediction when the echo mismatches", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => true);
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
    const ta = createTypeahead(term, () => true);
    ta.predict("a");
    ta.predict("b");

    // matched=1 but neither the pending nor the data was exhausted
    const out = ta.reconcile(bytes("axz"));
    expect(text(out)).toBe("\x1b[2D\x1b[Kaxz");
  });

  it("passes binary (non-UTF-8) bytes through byte-for-byte", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => true);

    const blob = new Uint8Array([0x00, 0xff, 0xfe, 0x80]);
    expect(ta.reconcile(blob)).toBe(blob);
  });

  it("prefixes the erase sequence to mismatching binary output", () => {
    const { term } = makeTerm();
    const ta = createTypeahead(term, () => true);
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
    const ta = createTypeahead(term, () => true);
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
    const ta = createTypeahead(term, () => true);
    ta.predict("a");
    ta.reconcile(bytes("a"));

    vi.advanceTimersByTime(5000);
    expect(writes).toEqual(["a"]); // no erase ever written
  });

  it("re-arms the timeout for the unconfirmed remainder after a partial echo", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => true);
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
    const ta = createTypeahead(term, () => true);

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
    const ta = createTypeahead(term, () => true);

    ta.reconcile(bytes("\x1b[?1049h"));
    ta.predict("a");
    expect(writes).toEqual([]);
  });

  it("keeps predicting through plain prompt output", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => true);

    ta.reconcile(bytes("user@host:~$ "));
    ta.predict("a");
    expect(writes).toEqual(["a"]);
  });
});

describe("abandon and dispose", () => {
  it("abandon drops the pending state without touching the screen", () => {
    const { term, writes } = makeTerm();
    const ta = createTypeahead(term, () => true);
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
    const ta = createTypeahead(term, () => true);
    ta.predict("a");

    ta.dispose();
    vi.advanceTimersByTime(2000);
    expect(writes).toEqual(["a"]);
  });
});
