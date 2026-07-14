import { describe, expect, it, beforeEach } from "vitest";
import {
  BINDINGS,
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

  it("bare function keys match, and reject held modifiers", () => {
    expect(matchCombo(key({ key: "F2" }), "f2")).toBe(true);
    expect(matchCombo(key({ key: "F2", ctrlKey: true }), "f2")).toBe(false);
    expect(matchCombo(key({ key: "F2", shiftKey: true }), "f2")).toBe(false);
    expect(matchCombo(key({ key: "f" }), "f2")).toBe(false);
  });

  it("Alt combos match by PHYSICAL key — macOS composes ⌥R into “®”", () => {
    // The trap: with Option held, macOS hands the page e.key = "®" (or "√",
    // "¬"…), so an e.key-based match would never fire for any Alt binding.
    expect(
      matchCombo(key({ key: "®", code: "KeyR", altKey: true, metaKey: true }), "mod+alt+r"),
    ).toBe(true);
    // Linux/Windows report the plain letter — same combo, same result.
    expect(
      matchCombo(key({ key: "r", code: "KeyR", altKey: true, ctrlKey: true }), "mod+alt+r"),
    ).toBe(true);
    // Alt must be REQUIRED: plain ⌘R (reload) must not rename.
    expect(matchCombo(key({ key: "r", code: "KeyR", metaKey: true }), "mod+alt+r")).toBe(false);
    // Digits too (Alt+2 composes on macOS as well).
    expect(
      matchCombo(key({ key: "€", code: "Digit2", altKey: true, ctrlKey: true }), "ctrl+alt+2"),
    ).toBe(true);
  });
});

describe("BINDINGS registry", () => {
  it("renames the session with ⌥⌘R / Ctrl+Alt+R by default (F2 costs an fn chord on a Mac)", () => {
    const spec = BINDINGS.find((b) => b.id === "renameSession");
    expect(spec).toBeDefined();
    expect(spec?.default).toBe("mod+alt+r");
    expect(spec?.scope).toBe("global");
    // Not mod+shift+r: that is the browser's hard-reload.
    expect(spec?.default).not.toBe("mod+shift+r");
    // Rename is a web-app-only action: it has no menu item, so nothing to
    // mirror. (F2 stays available as a REBIND — see the function-key tests.)
    expect(spec?.clientMenu).toBeUndefined();
  });

  it("ships no duplicate default combos within a scope", () => {
    const seen = new Set<string>();
    for (const spec of BINDINGS) {
      const combo = `${spec.scope}:${spec.default}`;
      expect(seen.has(combo)).toBe(false);
      seen.add(combo);
    }
  });
});

describe("comboFromEvent", () => {
  it("ignores bare modifiers and records combos", () => {
    expect(comboFromEvent(key({ key: "Shift", shiftKey: true }))).toBeNull();
    expect(comboFromEvent(key({ key: "k", ctrlKey: true, shiftKey: true }))).toBe("mod+shift+k");
  });

  it("records a bare function key", () => {
    expect(comboFromEvent(key({ key: "F2" }))).toBe("f2");
  });
});

describe("conversions", () => {
  it("formats for non-mac", () => {
    expect(formatCombo("mod+shift+k")).toBe("Ctrl+Shift+K");
    expect(formatCombo("shift+enter")).toBe("Shift+Enter");
  });

  it("formats function keys uppercase", () => {
    expect(formatCombo("f2")).toBe("F2");
    expect(formatCombo("f12")).toBe("F12");
  });

  it("codemirror keys", () => {
    expect(comboToCodeMirror("shift+enter")).toBe("Shift-Enter");
    expect(comboToCodeMirror("mod+shift+a")).toBe("Mod-Shift-a");
  });

  it("electron accelerators", () => {
    expect(comboToAccelerator("mod+shift+k")).toBe("CmdOrCtrl+Shift+K");
    expect(comboToAccelerator("ctrl+shift+`")).toBe("Ctrl+Shift+`");
  });

  it("electron accelerators keep function keys (F1–F24 are valid accelerators)", () => {
    // A user who remaps the composer/voice/quick-shell (the clientMenu
    // bindings) onto an F-key must not silently lose the menu accelerator.
    expect(comboToAccelerator("f2")).toBe("F2");
    expect(comboToAccelerator("mod+f5")).toBe("CmdOrCtrl+F5");
    expect(comboToAccelerator("shift+f12")).toBe("Shift+F12");
    expect(comboToAccelerator("f24")).toBe("F24");
    // Electron stops at F24; anything beyond is not an accelerator.
    expect(comboToAccelerator("f25")).toBeNull();
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
