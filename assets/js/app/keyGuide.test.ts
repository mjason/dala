import { describe, expect, it } from "vitest";
import { KEY_GUIDE } from "./keyGuide";
import { en } from "./i18n/locales";

describe("KEY_GUIDE", () => {
  it("covers the claude code, zellij and opencode groups", () => {
    expect(KEY_GUIDE.map((group) => group.app)).toEqual(
      expect.arrayContaining(["claude code", "zellij", "opencode"]),
    );
  });

  it("every group has a non-empty app label and at least one row", () => {
    for (const group of KEY_GUIDE) {
      expect(group.app.trim(), JSON.stringify(group)).not.toBe("");
      expect(group.rows.length, group.app).toBeGreaterThan(0);
    }
  });

  it("every row has at least one key step and no empty keys", () => {
    for (const group of KEY_GUIDE) {
      for (const row of group.rows) {
        expect(row.keys.length, `${group.app}: ${row.descKey}`).toBeGreaterThan(0);
        for (const key of row.keys) {
          expect(key.trim(), `${group.app}: ${row.descKey}`).not.toBe("");
        }
      }
    }
  });

  it("every description key resolves to a non-empty en message", () => {
    for (const group of KEY_GUIDE) {
      for (const row of group.rows) {
        const message = en[row.descKey];
        expect(typeof message, `${group.app}: ${row.descKey}`).toBe("string");
        expect(message.trim(), `${group.app}: ${row.descKey}`).not.toBe("");
      }
    }
  });

  it("claude code documents the Ctrl+O double-press re-render", () => {
    const claude = KEY_GUIDE.find((group) => group.app === "claude code");
    expect(claude?.rows.some((row) => row.keys.join(" ") === "Ctrl+O Ctrl+O")).toBe(true);
  });
});
