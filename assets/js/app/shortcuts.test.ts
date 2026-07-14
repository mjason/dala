import { beforeEach, describe, expect, it, vi } from "vitest";

type Shortcuts = typeof import("./shortcuts");

// The module keeps state at module level (the window stack) and computes
// `isMac` at import time, so every test gets a fresh copy via resetModules.
let shortcuts: Shortcuts;

beforeEach(async () => {
  vi.resetModules();
  shortcuts = await import("./shortcuts");
});

describe("window stack", () => {
  it("starts empty", () => {
    expect(shortcuts.hasOpenWindows()).toBe(false);
  });

  it("the most recently pushed window is on top", () => {
    const first = shortcuts.pushWindow();
    const second = shortcuts.pushWindow();

    expect(shortcuts.hasOpenWindows()).toBe(true);
    expect(shortcuts.isTopWindow(second)).toBe(true);
    expect(shortcuts.isTopWindow(first)).toBe(false);
  });

  it("popping the top window promotes the one underneath", () => {
    const first = shortcuts.pushWindow();
    const second = shortcuts.pushWindow();

    shortcuts.popWindow(second);
    expect(shortcuts.isTopWindow(first)).toBe(true);
    expect(shortcuts.hasOpenWindows()).toBe(true);

    shortcuts.popWindow(first);
    expect(shortcuts.hasOpenWindows()).toBe(false);
  });

  it("popping a window from the middle keeps the top intact", () => {
    const bottom = shortcuts.pushWindow();
    const middle = shortcuts.pushWindow();
    const top = shortcuts.pushWindow();

    shortcuts.popWindow(middle);
    expect(shortcuts.isTopWindow(top)).toBe(true);
    expect(shortcuts.isTopWindow(bottom)).toBe(false);
    expect(shortcuts.hasOpenWindows()).toBe(true);
  });

  it("every push mints a distinct token, even for look-alike windows", () => {
    const first = shortcuts.pushWindow();
    const second = shortcuts.pushWindow();

    expect(first).not.toBe(second);
    // popping one leaves the other open
    shortcuts.popWindow(first);
    expect(shortcuts.isTopWindow(second)).toBe(true);
  });

  it("popping an unknown or already-popped token is a no-op", () => {
    const token = shortcuts.pushWindow();
    shortcuts.popWindow(Symbol("stranger"));
    expect(shortcuts.isTopWindow(token)).toBe(true);

    shortcuts.popWindow(token);
    shortcuts.popWindow(token); // double pop
    expect(shortcuts.hasOpenWindows()).toBe(false);
  });
});

describe("shortcut labels", () => {
  it("uses Ctrl on non-Apple platforms", () => {
    // jsdom's default platform is not Mac-like
    expect(shortcuts.isMac).toBe(false);
    expect(shortcuts.modLabel).toBe("Ctrl");
    expect(shortcuts.modCombo("k")).toBe("Ctrl+K");
    expect(shortcuts.modShiftCombo("s")).toBe("Ctrl+Shift+S");
  });

  it("uppercases the key in the label", () => {
    expect(shortcuts.modCombo("p")).toBe("Ctrl+P");
    expect(shortcuts.modShiftCombo("p")).toBe("Ctrl+Shift+P");
  });

  it("uses Apple glyphs on Mac and iOS platforms", async () => {
    const original = navigator.platform;
    try {
      Object.defineProperty(navigator, "platform", { value: "MacIntel", configurable: true });
      vi.resetModules();
      const mac = await import("./shortcuts");
      expect(mac.isMac).toBe(true);
      expect(mac.modLabel).toBe("⌘");
      expect(mac.modCombo("k")).toBe("⌘K");
      expect(mac.modShiftCombo("s")).toBe("⇧⌘S");

      Object.defineProperty(navigator, "platform", { value: "iPhone", configurable: true });
      vi.resetModules();
      const ios = await import("./shortcuts");
      expect(ios.isMac).toBe(true);
    } finally {
      Object.defineProperty(navigator, "platform", { value: original, configurable: true });
    }
  });
});

describe("inTextInput", () => {
  it("recognizes form fields", () => {
    expect(shortcuts.inTextInput({ target: document.createElement("input") })).toBe(true);
    expect(shortcuts.inTextInput({ target: document.createElement("textarea") })).toBe(true);
    expect(shortcuts.inTextInput({ target: document.createElement("select") })).toBe(true);
  });

  it("recognizes contenteditable regions, including nested targets", () => {
    const editable = document.createElement("div");
    editable.setAttribute("contenteditable", "true");
    expect(shortcuts.inTextInput({ target: editable })).toBe(true);

    const child = document.createElement("span");
    editable.appendChild(child);
    expect(shortcuts.inTextInput({ target: child })).toBe(true);
  });

  it("recognizes bare `contenteditable` and plaintext-only variants", () => {
    const bare = document.createElement("div");
    bare.setAttribute("contenteditable", "");
    expect(shortcuts.inTextInput({ target: bare })).toBe(true);

    const child = document.createElement("span");
    bare.appendChild(child);
    expect(shortcuts.inTextInput({ target: child })).toBe(true);

    const plain = document.createElement("div");
    plain.setAttribute("contenteditable", "plaintext-only");
    expect(shortcuts.inTextInput({ target: plain })).toBe(true);
  });

  it("rejects plain elements, contenteditable=false and missing targets", () => {
    expect(shortcuts.inTextInput({ target: document.createElement("div") })).toBe(false);

    const notEditable = document.createElement("div");
    notEditable.setAttribute("contenteditable", "false");
    expect(shortcuts.inTextInput({ target: notEditable })).toBe(false);

    expect(shortcuts.inTextInput({ target: null })).toBe(false);
  });

  it("finds the wrapping field when the target sits inside it", () => {
    const label = document.createElement("label");
    const input = document.createElement("input");
    label.appendChild(input);
    expect(shortcuts.inTextInput({ target: input })).toBe(true);
    expect(shortcuts.inTextInput({ target: label })).toBe(false);
  });
});

describe("focusOrphaned", () => {
  it("is true when nothing (or only <body>) holds focus", () => {
    expect(shortcuts.focusOrphaned()).toBe(true);
  });

  it("is false while a real element holds focus — never steal it back", () => {
    const input = document.createElement("input");
    document.body.appendChild(input);
    input.focus();
    try {
      expect(shortcuts.focusOrphaned()).toBe(false);
    } finally {
      input.remove();
    }
  });
});
