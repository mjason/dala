import { describe, expect, it } from "vitest";
import { GLOBAL_THEME_OWNER, relevantThemeOwner } from "./themeLibrary";

const row = (ownerId: string) => ({ ownerId });

describe("relevantThemeOwner", () => {
  it("accepts the global/anonymous sentinel regardless of library contents", () => {
    expect(relevantThemeOwner(GLOBAL_THEME_OWNER, [])).toBe(true);
    expect(relevantThemeOwner(GLOBAL_THEME_OWNER, [row("someone")])).toBe(true);
  });

  it("accepts an owner already present in my library (my own rows)", () => {
    const lib = [row(GLOBAL_THEME_OWNER), row("mine-123")];
    expect(relevantThemeOwner("mine-123", lib)).toBe(true);
  });

  it("ignores an owner I cannot see (a different signed-in owner)", () => {
    const lib = [row(GLOBAL_THEME_OWNER)];
    expect(relevantThemeOwner("stranger-999", lib)).toBe(false);
  });

  it("accepts my own owner id even before any owned row exists (first theme sync)", () => {
    // A brand-new device: library is still only the global presets, so there is
    // no owned row to match — but the join reply told us our own owner id.
    const lib = [row(GLOBAL_THEME_OWNER)];
    expect(relevantThemeOwner("me-1", lib, "me-1")).toBe(true);
  });

  it("still ignores a stranger when my own owner id is known", () => {
    const lib = [row(GLOBAL_THEME_OWNER)];
    expect(relevantThemeOwner("stranger-999", lib, "me-1")).toBe(false);
  });
});
