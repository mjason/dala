import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  COARSE_POINTER_FONT_SIZE,
  DEFAULT_PREFS,
  defaultFontSize,
  fontStack,
  loadPrefs,
  onPrefsChange,
  resetPrefs,
  savePrefs,
} from "./termPrefs";

beforeEach(() => {
  localStorage.clear();
});

describe("termPrefs", () => {
  it("returns defaults when nothing is stored or storage is corrupt", () => {
    expect(loadPrefs()).toEqual(DEFAULT_PREFS);
    localStorage.setItem("dala:term-prefs", "not json{");
    expect(loadPrefs()).toEqual(DEFAULT_PREFS);
  });

  it("persists merged patches and clamps out-of-range values", () => {
    savePrefs({ fontSize: 99, lineHeight: 0.2, cursorStyle: "block" });
    const prefs = loadPrefs();
    expect(prefs.fontSize).toBe(24); // clamped to max
    expect(prefs.lineHeight).toBe(1); // clamped to min
    expect(prefs.cursorStyle).toBe("block");
    expect(prefs.cursorBlink).toBe(DEFAULT_PREFS.cursorBlink);
  });

  it("rejects unknown cursor styles", () => {
    savePrefs({ cursorStyle: "wat" as never });
    expect(loadPrefs().cursorStyle).toBe(DEFAULT_PREFS.cursorStyle);
  });

  it("notifies subscribers on change and stops after unsubscribe", () => {
    const seen = vi.fn();
    const stop = onPrefsChange(seen);

    savePrefs({ fontSize: 18 });
    expect(seen).toHaveBeenCalledWith(expect.objectContaining({ fontSize: 18 }));

    stop();
    savePrefs({ fontSize: 16 });
    expect(seen).toHaveBeenCalledTimes(1);
  });

  it("resetPrefs restores defaults", () => {
    savePrefs({ fontSize: 20, fontFamily: "Fira Code" });
    expect(resetPrefs()).toEqual(DEFAULT_PREFS);
    expect(loadPrefs()).toEqual(DEFAULT_PREFS);
  });

  describe("device-aware default font size (pointer: coarse)", () => {
    // jsdom has no media query engine — stub matchMedia per test.
    const stubPointer = (coarse: boolean) =>
      vi.stubGlobal(
        "matchMedia",
        vi.fn().mockReturnValue({ matches: coarse } as MediaQueryList),
      );

    afterEach(() => {
      vi.unstubAllGlobals();
    });

    it("defaults to the larger touch font when nothing is stored", () => {
      stubPointer(true);
      expect(defaultFontSize()).toBe(COARSE_POINTER_FONT_SIZE);
      expect(loadPrefs().fontSize).toBe(COARSE_POINTER_FONT_SIZE);
    });

    it("keeps the desktop default on fine pointers", () => {
      stubPointer(false);
      expect(defaultFontSize()).toBe(DEFAULT_PREFS.fontSize);
      expect(loadPrefs().fontSize).toBe(DEFAULT_PREFS.fontSize);
    });

    it("an explicitly stored fontSize wins over the device default", () => {
      stubPointer(true);
      savePrefs({ fontSize: 12 });
      expect(loadPrefs().fontSize).toBe(12);
    });

    it("resetPrefs restores the device default, not the desktop constant", () => {
      stubPointer(true);
      savePrefs({ fontSize: 20 });
      expect(resetPrefs().fontSize).toBe(COARSE_POINTER_FONT_SIZE);
    });
  });

  it("builds the font stack with the bundled font as fallback", () => {
    expect(fontStack(DEFAULT_PREFS)).toBe('"JetBrainsMono NFM", monospace');
    expect(fontStack({ ...DEFAULT_PREFS, fontFamily: "Fira Code, monospace" })).toBe(
      '"Fira Code", monospace, "JetBrainsMono NFM", monospace',
    );
    expect(fontStack({ ...DEFAULT_PREFS, fontFamily: '"Cascadia Mono"' })).toBe(
      '"Cascadia Mono", "JetBrainsMono NFM", monospace',
    );
  });
});
