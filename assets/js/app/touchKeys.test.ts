import { describe, expect, it } from "vitest";
import { applyCtrl, nextLatch, sequenceFor, type BarKey } from "./touchKeys";

describe("sequenceFor", () => {
  it("maps the plain bar keys to their escape bytes", () => {
    expect(sequenceFor("esc", false)).toBe("\x1b");
    expect(sequenceFor("tab", false)).toBe("\t");
    expect(sequenceFor("up", false)).toBe("\x1b[A");
    expect(sequenceFor("down", false)).toBe("\x1b[B");
    expect(sequenceFor("left", false)).toBe("\x1b[D");
    expect(sequenceFor("right", false)).toBe("\x1b[C");
    expect(sequenceFor("ctrl-c", false)).toBe("\x03");
  });

  it("sends CSI 1;5 word-movement arrows while Ctrl is latched", () => {
    expect(sequenceFor("up", true)).toBe("\x1b[1;5A");
    expect(sequenceFor("down", true)).toBe("\x1b[1;5B");
    expect(sequenceFor("left", true)).toBe("\x1b[1;5D");
    expect(sequenceFor("right", true)).toBe("\x1b[1;5C");
  });

  it("keys without a Ctrl variant fall back to their plain sequence", () => {
    expect(sequenceFor("esc", true)).toBe("\x1b");
    expect(sequenceFor("tab", true)).toBe("\t");
    expect(sequenceFor("ctrl-c", true)).toBe("\x03");
  });
});

describe("applyCtrl", () => {
  it("maps letters to C0 control bytes, case-insensitively", () => {
    expect(applyCtrl("c")).toBe("\x03");
    expect(applyCtrl("C")).toBe("\x03");
    expect(applyCtrl("a")).toBe("\x01");
    expect(applyCtrl("d")).toBe("\x04");
    expect(applyCtrl("z")).toBe("\x1a");
  });

  it("maps the classic symbol combos", () => {
    expect(applyCtrl("[")).toBe("\x1b");
    expect(applyCtrl("]")).toBe("\x1d");
    expect(applyCtrl("\\")).toBe("\x1c");
    expect(applyCtrl("@")).toBe("\x00");
    expect(applyCtrl(" ")).toBe("\x00");
    expect(applyCtrl("?")).toBe("\x7f");
  });

  it("returns null when Ctrl cannot apply, keeping the latch armed", () => {
    expect(applyCtrl("")).toBeNull();
    expect(applyCtrl("ab")).toBeNull(); // paste / IME commit
    expect(applyCtrl("汉")).toBeNull();
    expect(applyCtrl("1")).toBeNull();
    expect(applyCtrl(".")).toBeNull();
  });
});

describe("nextLatch", () => {
  it("Ctrl toggles itself", () => {
    expect(nextLatch("ctrl", false)).toBe(true);
    expect(nextLatch("ctrl", true)).toBe(false);
  });

  it("sending any key consumes the latch", () => {
    const keys: BarKey[] = ["esc", "tab", "up", "down", "left", "right", "ctrl-c"];
    for (const key of keys) {
      expect(nextLatch(key, true)).toBe(false);
      expect(nextLatch(key, false)).toBe(false);
    }
  });
});
