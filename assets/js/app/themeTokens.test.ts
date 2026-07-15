import { describe, expect, it } from "vitest";
import { TOKEN_KEYS, TOKEN_TO_CSSVAR, TOKEN_TO_ITHEME } from "./themeTokens";

describe("themeTokens contract", () => {
  it("declares exactly 39 unique token keys", () => {
    expect(TOKEN_KEYS).toHaveLength(39);
    expect(new Set(TOKEN_KEYS).size).toBe(39);
  });

  it("the two target maps have the documented sizes", () => {
    expect(Object.keys(TOKEN_TO_CSSVAR)).toHaveLength(18);
    expect(Object.keys(TOKEN_TO_ITHEME)).toHaveLength(21);
  });

  it("the two maps PARTITION all 39 keys — no overlap, no omission", () => {
    const cssVarKeys = Object.keys(TOKEN_TO_CSSVAR);
    const iThemeKeys = Object.keys(TOKEN_TO_ITHEME);

    // No key is in both maps.
    const overlap = cssVarKeys.filter((k) => iThemeKeys.includes(k));
    expect(overlap).toEqual([]);

    // Together they cover every token key, and nothing extra.
    const union = new Set([...cssVarKeys, ...iThemeKeys]);
    expect(union.size).toBe(39);
    for (const key of TOKEN_KEYS) {
      expect(union.has(key)).toBe(true);
    }
    // And every mapped key is a real token key.
    for (const key of union) {
      expect(TOKEN_KEYS).toContain(key);
    }
  });

  it("every CSS-var target is a `--color-*` custom property", () => {
    for (const cssvar of Object.values(TOKEN_TO_CSSVAR)) {
      expect(cssvar.startsWith("--color-")).toBe(true);
    }
  });

  it("CSS-var and ITheme targets are each internally unique", () => {
    const cssVars = Object.values(TOKEN_TO_CSSVAR);
    expect(new Set(cssVars).size).toBe(cssVars.length);
    const fields = Object.values(TOKEN_TO_ITHEME);
    expect(new Set(fields).size).toBe(fields.length);
  });

  it("pins the exact app.css var names and xterm ITheme fields", () => {
    // UI + diff + cm → --color-* (verified against assets/css/app.css)
    expect(TOKEN_TO_CSSVAR.fgMuted).toBe("--color-fg-muted");
    expect(TOKEN_TO_CSSVAR.diffAddFg).toBe("--color-diff-add-fg");
    expect(TOKEN_TO_CSSVAR.cmGutterBg).toBe("--color-cm-gutter-bg");
    expect(TOKEN_TO_CSSVAR.cmSelection).toBe("--color-cm-selection");
    // term base + ANSI → xterm ITheme fields (verified against terminalTheme.ts)
    expect(TOKEN_TO_ITHEME.termBackground).toBe("background");
    expect(TOKEN_TO_ITHEME.termSelectionBackground).toBe("selectionBackground");
    expect(TOKEN_TO_ITHEME.ansiBrightBlack).toBe("brightBlack");
    expect(TOKEN_TO_ITHEME.ansiWhite).toBe("white");
  });
});
