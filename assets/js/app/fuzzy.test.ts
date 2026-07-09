import { describe, expect, it } from "vitest";
import { fuzzyMatch, rankFiles } from "./fuzzy";

describe("fuzzyMatch", () => {
  it("requires all query chars in order", () => {
    expect(fuzzyMatch("abc", "a-b-c")).not.toBeNull();
    expect(fuzzyMatch("acb", "abc")).toBeNull();
    expect(fuzzyMatch("xyz", "abc")).toBeNull();
  });

  it("is case-insensitive and reports positions", () => {
    const match = fuzzyMatch("RC", "src/Rc.ts");
    expect(match).not.toBeNull();
    expect(match!.positions).toEqual([1, 2]);
  });

  it("empty query matches everything", () => {
    expect(fuzzyMatch("", "anything")).toEqual({ score: 0, positions: [] });
  });
});

describe("rankFiles", () => {
  const files = [
    "lib/dala/terminal/server.ex",
    "lib/dala_web/endpoint.ex",
    "assets/js/app/TerminalView.tsx",
    "test/dala/terminal/server_test.exs",
    "README.md",
  ];

  it("ranks basename segment matches above scattered ones", () => {
    const ranked = rankFiles("server", files).map((r) => r.path);
    expect(ranked[0]).toBe("lib/dala/terminal/server.ex");
    expect(ranked).toContain("test/dala/terminal/server_test.exs");
  });

  it("supports path-style queries", () => {
    const ranked = rankFiles("term/serv", files).map((r) => r.path);
    expect(ranked[0]).toBe("lib/dala/terminal/server.ex");
  });

  it("returns everything (capped) for empty queries and nothing for misses", () => {
    expect(rankFiles("", files)).toHaveLength(files.length);
    expect(rankFiles("zzzzzz", files)).toHaveLength(0);
    expect(rankFiles("", files, 2)).toHaveLength(2);
  });
});
