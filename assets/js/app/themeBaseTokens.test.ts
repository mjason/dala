import { describe, expect, it } from "vitest";
import { baseTokenValue, baseTokens } from "./themeBaseTokens";
import { TOKEN_KEYS } from "./themeTokens";

describe("baseTokenValue", () => {
  it("reads UI/diff/cm defaults from the app.css palette", () => {
    expect(baseTokenValue("dark", "bg0")).toBe("#0b0c0e");
    expect(baseTokenValue("light", "bg0")).toBe("#fbfbfa");
    expect(baseTokenValue("dark", "diffAddBg")).toBe("rgba(95, 191, 135, 0.11)");
    expect(baseTokenValue("light", "gitConflict")).toBe("#6639ba");
    expect(baseTokenValue("dark", "gitDeleted")).toBe("#d27d9f");
    expect(baseTokenValue("light", "gitIgnored")).toBe("#68727c");
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
