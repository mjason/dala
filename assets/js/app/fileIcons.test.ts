import { describe, expect, it } from "vitest";
import { fileIcon } from "./fileIcons";

describe("fileIcon", () => {
  it("maps directories, open and closed", () => {
    const closed = fileIcon("src", true, false);
    const open = fileIcon("src", true, true);
    expect(closed.glyph).not.toBe(open.glyph);
    expect(closed.color).toContain("6d9fd6");
  });

  it("maps languages by extension with distinct colors", () => {
    expect(fileIcon("app.ex").color).toContain("b087c9");
    expect(fileIcon("main.ts").color).toContain("6d9fd6");
    expect(fileIcon("script.py").color).toContain("d9a860");
    expect(fileIcon("go.mod")).toBeTruthy();
  });

  it("is case-insensitive and path-aware", () => {
    expect(fileIcon("/a/b/App.EX").glyph).toBe(fileIcon("app.ex").glyph);
  });

  it("maps well-known file names", () => {
    expect(fileIcon("Dockerfile").glyph).toBe(fileIcon("dockerfile").glyph);
    expect(fileIcon("package.json").color).toContain("e5716e");
    expect(fileIcon(".gitignore")).toBeTruthy();
  });

  it("falls back for unknown types", () => {
    const fallback = fileIcon("mystery.qwerty");
    expect(fallback.glyph).toBeTruthy();
    expect(fallback.color).toBe("text-fg-muted");
  });
});
