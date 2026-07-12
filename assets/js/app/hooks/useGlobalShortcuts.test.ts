import { describe, expect, it } from "vitest";
import { deferToTerminal } from "./useGlobalShortcuts";

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
