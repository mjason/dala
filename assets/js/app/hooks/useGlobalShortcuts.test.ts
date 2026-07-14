import { afterEach, describe, expect, it } from "vitest";
import { deferToTerminal, renameBlocked } from "./useGlobalShortcuts";
import { popWindow, pushWindow } from "../shortcuts";

const makeTarget = (inXterm: boolean): EventTarget => {
  const outer = document.createElement("div");
  if (inXterm) outer.className = "xterm";
  const inner = document.createElement("span");
  outer.appendChild(inner);
  return inner;
};

describe("deferToTerminal", () => {
  it("defers plain combos typed inside the terminal", () => {
    expect(
      deferToTerminal({ target: makeTarget(true), metaKey: false, shiftKey: false }),
    ).toBe(true);
  });

  it("does not defer when ⌘ or shift is held", () => {
    expect(deferToTerminal({ target: makeTarget(true), metaKey: true, shiftKey: false })).toBe(
      false,
    );
    expect(deferToTerminal({ target: makeTarget(true), metaKey: false, shiftKey: true })).toBe(
      false,
    );
  });

  it("does not defer outside the terminal", () => {
    expect(
      deferToTerminal({ target: makeTarget(false), metaKey: false, shiftKey: false }),
    ).toBe(false);
    expect(deferToTerminal({ target: null, metaKey: false, shiftKey: false })).toBe(false);
  });
});

// F2 is a BARE key: unlike the mod+letter shortcuts it collides with typing,
// so it needs guards the others don't.
describe("renameBlocked", () => {
  const windows: symbol[] = [];
  afterEach(() => {
    while (windows.length) popWindow(windows.pop() as symbol);
  });

  it("fires with the terminal focused — that is the main use case", () => {
    expect(renameBlocked({ target: makeTarget(true) })).toBe(false);
  });

  it("fires from xterm's own hidden textarea (a text input, but in the terminal)", () => {
    const term = document.createElement("div");
    term.className = "xterm";
    const helper = document.createElement("textarea");
    term.appendChild(helper);
    expect(renameBlocked({ target: helper })).toBe(false);
  });

  it("fires from chrome that is not a text field (sidebar row, body)", () => {
    expect(renameBlocked({ target: makeTarget(false) })).toBe(false);
    expect(renameBlocked({ target: document.body })).toBe(false);
  });

  it("is blocked inside a text input (composer, git commit box, rename input itself)", () => {
    expect(renameBlocked({ target: document.createElement("textarea") })).toBe(true);
    expect(renameBlocked({ target: document.createElement("input") })).toBe(true);
    const editable = document.createElement("div");
    editable.setAttribute("contenteditable", "");
    expect(renameBlocked({ target: editable })).toBe(true);
  });

  it("is blocked while any window is open (QuickOpen, settings modal, shortcut recorder)", () => {
    windows.push(pushWindow());
    // ...even when the terminal has focus behind the modal.
    expect(renameBlocked({ target: makeTarget(true) })).toBe(true);
    expect(renameBlocked({ target: makeTarget(false) })).toBe(true);
  });
});
