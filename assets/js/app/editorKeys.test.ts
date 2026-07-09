import { describe, expect, it } from "vitest";
import { handleEnter, handleTab, isSaveShortcut } from "./editorKeys";

describe("handleTab", () => {
  it("inserts indent at the caret", () => {
    const r = handleTab("abc", 1, 1, false);
    expect(r.value).toBe("a  bc");
    expect(r.selectionStart).toBe(3);
    expect(r.selectionEnd).toBe(3);
  });

  it("indents every line of a multi-line selection", () => {
    const value = "one\ntwo\nthree";
    const r = handleTab(value, 0, value.length, false);
    expect(r.value).toBe("  one\n  two\n  three");
  });

  it("outdents with Shift+Tab", () => {
    const value = "  one\n    two";
    const r = handleTab(value, 0, value.length, true);
    expect(r.value).toBe("one\n  two");
  });

  it("outdent stops at column zero", () => {
    const value = "no indent";
    const r = handleTab(value, 0, value.length, true);
    expect(r.value).toBe("no indent");
  });
});

describe("handleEnter", () => {
  it("carries the leading whitespace to the new line", () => {
    const value = "    foo";
    const r = handleEnter(value, value.length, value.length);
    expect(r.value).toBe("    foo\n    ");
    expect(r.selectionStart).toBe(value.length + 5);
  });

  it("adds no indent on an unindented line", () => {
    const r = handleEnter("bar", 3, 3);
    expect(r.value).toBe("bar\n");
  });
});

describe("isSaveShortcut", () => {
  it("recognizes Cmd/Ctrl+S", () => {
    expect(isSaveShortcut({ key: "s", metaKey: true, ctrlKey: false })).toBe(true);
    expect(isSaveShortcut({ key: "S", metaKey: false, ctrlKey: true })).toBe(true);
  });

  it("ignores plain s and other combos", () => {
    expect(isSaveShortcut({ key: "s", metaKey: false, ctrlKey: false })).toBe(false);
    expect(isSaveShortcut({ key: "a", metaKey: true, ctrlKey: false })).toBe(false);
  });
});
