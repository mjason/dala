import { describe, expect, it } from "vitest";
import { fileIcon } from "./fileIcons";

describe("fileIcon", () => {
  it("maps directories, open and closed", () => {
    const closed = fileIcon("src", true, false);
    const open = fileIcon("src", true, true);
    expect(closed.glyph).not.toBe(open.glyph);
    expect(closed.color).toBe("text-dala-info");
  });

  it("maps languages by extension with distinct colors", () => {
    expect(fileIcon("app.ex").color).toBe("text-dala-magenta");
    expect(fileIcon("main.ts").color).toBe("text-dala-info");
    expect(fileIcon("script.py").color).toBe("text-dala-warning");
    expect(fileIcon("go.mod")).toBeTruthy();
  });

  it("is case-insensitive and path-aware", () => {
    expect(fileIcon("/a/b/App.EX").glyph).toBe(fileIcon("app.ex").glyph);
  });

  it("maps well-known file names", () => {
    expect(fileIcon("Dockerfile").glyph).toBe(fileIcon("dockerfile").glyph);
    expect(fileIcon("package.json").color).toBe("text-danger");
    expect(fileIcon(".gitignore")).toBeTruthy();
  });

  it("falls back for unknown types", () => {
    const fallback = fileIcon("mystery.qwerty");
    expect(fallback.glyph).toBeTruthy();
    expect(fallback.color).toBe("text-fg-muted");
  });
});
