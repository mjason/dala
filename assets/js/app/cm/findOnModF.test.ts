import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const openSearchPanel = vi.fn();
vi.mock("@codemirror/search", () => ({
  openSearchPanel: (...args: unknown[]) => openSearchPanel(...args),
}));
// Test the non-mac branch (Ctrl); isMac is a module-load constant.
vi.mock("../shortcuts", () => ({ isMac: false }));

import { findOnModF } from "./findOnModF";

function fakeView() {
  return { focus: vi.fn() } as unknown as import("@codemirror/view").EditorView;
}

function press(opts: KeyboardEventInit) {
  const e = new KeyboardEvent("keydown", { key: "f", cancelable: true, ...opts });
  window.dispatchEvent(e);
  return e;
}

describe("findOnModF", () => {
  let stop: () => void;
  let view: ReturnType<typeof fakeView>;

  beforeEach(() => {
    openSearchPanel.mockClear();
    view = fakeView();
    stop = findOnModF(view);
  });
  afterEach(() => stop());

  it("Ctrl+F opens the search panel, focuses the editor, and prevents the native find", () => {
    const e = press({ ctrlKey: true });
    expect(e.defaultPrevented).toBe(true);
    expect((view as unknown as { focus: () => void }).focus).toHaveBeenCalled();
    expect(openSearchPanel).toHaveBeenCalledWith(view);
  });

  it("ignores an event a focused editor's own searchKeymap already handled", () => {
    // A capture-phase listener preventDefaults first, like the editor's keymap.
    const swallow = (e: Event) => e.preventDefault();
    window.addEventListener("keydown", swallow, true);
    press({ ctrlKey: true });
    window.removeEventListener("keydown", swallow, true);
    expect(openSearchPanel).not.toHaveBeenCalled();
  });

  it("leaves Shift+F / Alt+F and a bare F to the editor/shell", () => {
    press({ ctrlKey: true, shiftKey: true });
    press({ ctrlKey: true, altKey: true });
    press({});
    expect(openSearchPanel).not.toHaveBeenCalled();
  });

  it("stops intercepting once disposed", () => {
    stop();
    stop = () => {};
    press({ ctrlKey: true });
    expect(openSearchPanel).not.toHaveBeenCalled();
  });
});
