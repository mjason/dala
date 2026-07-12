import { describe, expect, it, beforeEach } from "vitest";
import {
  comboFromEvent,
  comboToAccelerator,
  comboToCodeMirror,
  formatCombo,
  loadBindings,
  matchCombo,
  resetBindings,
  saveBinding,
} from "./keybindings";

function key(init: Partial<KeyboardEvent> & { key: string; code?: string }): KeyboardEvent {
  return {
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    shiftKey: false,
    code: "",
    ...init,
  } as KeyboardEvent;
}

describe("matchCombo", () => {
  it("mod accepts ctrl or meta", () => {
    expect(matchCombo(key({ key: "k", ctrlKey: true, shiftKey: true }), "mod+shift+k")).toBe(true);
    expect(matchCombo(key({ key: "k", metaKey: true, shiftKey: true }), "mod+shift+k")).toBe(true);
    expect(matchCombo(key({ key: "k", shiftKey: true }), "mod+shift+k")).toBe(false);
  });

  it("shift must match exactly", () => {
    expect(matchCombo(key({ key: "p", ctrlKey: true, shiftKey: true }), "mod+p")).toBe(false);
    expect(matchCombo(key({ key: "p", ctrlKey: true }), "mod+p")).toBe(true);
  });

  it("plain combos reject held modifiers", () => {
    expect(matchCombo(key({ key: "Enter", shiftKey: true }), "shift+enter")).toBe(true);
    expect(matchCombo(key({ key: "Enter", shiftKey: true, ctrlKey: true }), "shift+enter")).toBe(
      false,
    );
  });

  it("backquote works via code", () => {
    expect(matchCombo(key({ key: "`", code: "Backquote", ctrlKey: true }), "ctrl+`")).toBe(true);
  });
});

describe("comboFromEvent", () => {
  it("ignores bare modifiers and records combos", () => {
    expect(comboFromEvent(key({ key: "Shift", shiftKey: true }))).toBeNull();
    expect(comboFromEvent(key({ key: "k", ctrlKey: true, shiftKey: true }))).toBe("mod+shift+k");
  });
});

describe("conversions", () => {
  it("formats for non-mac", () => {
    expect(formatCombo("mod+shift+k")).toBe("Ctrl+Shift+K");
    expect(formatCombo("shift+enter")).toBe("Shift+Enter");
  });

  it("codemirror keys", () => {
    expect(comboToCodeMirror("shift+enter")).toBe("Shift-Enter");
    expect(comboToCodeMirror("mod+shift+a")).toBe("Mod-Shift-a");
  });

  it("electron accelerators", () => {
    expect(comboToAccelerator("mod+shift+k")).toBe("CmdOrCtrl+Shift+K");
    expect(comboToAccelerator("ctrl+shift+`")).toBe("Ctrl+Shift+`");
  });
});

describe("persistence", () => {
  beforeEach(() => localStorage.clear());

  it("saves, loads and resets", () => {
    expect(loadBindings().composer).toBe("mod+shift+k");
    saveBinding("composer", "mod+shift+j");
    expect(loadBindings().composer).toBe("mod+shift+j");
    resetBindings();
    expect(loadBindings().composer).toBe("mod+shift+k");
  });
});
