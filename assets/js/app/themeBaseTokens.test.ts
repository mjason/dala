import { describe, expect, it } from "vitest";
import { baseTokenValue, baseTokens } from "./themeBaseTokens";
import { TOKEN_KEYS } from "./themeTokens";

describe("baseTokenValue", () => {
  it("reads UI/diff/cm defaults from the app.css palette", () => {
    expect(baseTokenValue("dark", "bg0")).toBe("#0b0c0e");
    expect(baseTokenValue("light", "bg0")).toBe("#fbfbfa");
    expect(baseTokenValue("dark", "diffAddBg")).toBe("rgba(95, 191, 135, 0.11)");
    expect(baseTokenValue("light", "gitConflict")).toBe("#6639ba");
    expect(baseTokenValue("light", "gitIgnored")).toBe("#68727c");
    // Deleted is a red-orange (VSCode-style), NOT the old magenta-pink; modified
    // is a clear gold. Pinned here + in palette.ex/app.css — keep the three in sync.
    expect(baseTokenValue("dark", "gitDeleted")).toBe("#e0705a");
    expect(baseTokenValue("light", "gitDeleted")).toBe("#a83a1e");
    expect(baseTokenValue("dark", "gitModified")).toBe("#e2c08d");
    expect(baseTokenValue("light", "gitModified")).toBe("#8a5a00");
  });

  it("derives terminal/ANSI defaults from the canonical xterm palettes", () => {
    expect(baseTokenValue("dark", "termBackground")).toBe("#0b0c0e");
    expect(baseTokenValue("dark", "ansiRed")).toBe("#e5716e");
    expect(baseTokenValue("light", "ansiRed")).toBe("#cf222e");
  });

  it("keeps deleted-file status visually separate from destructive actions", () => {
    for (const base of ["light", "dark"] as const) {
      expect(baseTokenValue(base, "gitDeleted")).not.toBe(baseTokenValue(base, "danger"));
    }
  });
});

describe("baseTokens", () => {
  it("fills every one of the 46 tokens for both bases", () => {
    for (const base of ["light", "dark"] as const) {
      const map = baseTokens(base);
      for (const key of TOKEN_KEYS) {
        expect(map[key], `${base}/${key}`).toBeTruthy();
      }
      expect(Object.keys(map)).toHaveLength(TOKEN_KEYS.length);
    }
  });
});
