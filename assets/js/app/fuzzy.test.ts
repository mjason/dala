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
    // "rc" also occurs inside "src", but the basename occurrence wins.
    expect(match!.positions).toEqual([4, 5]);
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

describe("unicode normalization", () => {
  it("matches NFD candidates against NFC queries", () => {
    // "café.md" with a decomposed é (e + combining acute) — macOS-style.
    const nfd = "docs/café.md";
    expect(fuzzyMatch("café", nfd)).not.toBeNull();
    expect(rankFiles("café", [nfd]).map((r) => r.path)).toEqual([nfd]);
  });

  it("matches NFC candidates against NFD queries", () => {
    expect(fuzzyMatch("café", "docs/café.md")).not.toBeNull();
  });
});

describe("path-shaped queries", () => {
  const files = ["lib/foo.ex", "lib/dala/terminal/server.ex"];

  it("strips the absolute root prefix so full paths hit exactly", () => {
    const ranked = rankFiles("/abs/root/lib/foo.ex", files, 10, "/abs/root");
    expect(ranked[0]?.path).toBe("lib/foo.ex");
    // Exact hit: the whole candidate is highlighted.
    expect(ranked[0]?.positions).toEqual([...Array("lib/foo.ex".length).keys()]);
  });

  it("tolerates a trailing slash on the root", () => {
    expect(rankFiles("/abs/root/lib/foo.ex", files, 10, "/abs/root/")[0]?.path).toBe("lib/foo.ex");
  });

  it("strips a differently-cased root (case-insensitive filesystems)", () => {
    expect(rankFiles("/Abs/Root/lib/foo.ex", files, 10, "/abs/root")[0]?.path).toBe("lib/foo.ex");
  });

  it("strips a Windows drive root from a pasted path", () => {
    expect(
      rankFiles("C:\\Work\\Repo\\lib\\foo.ex", files, 10, "c:\\work\\repo")[0]?.path,
    ).toBe("lib/foo.ex");
  });

  it("strips a leading ./ and a leading /", () => {
    expect(rankFiles("./lib/foo.ex", files)[0]?.path).toBe("lib/foo.ex");
    expect(rankFiles("/lib/foo.ex", files)[0]?.path).toBe("lib/foo.ex");
  });

  it("still matches when no root is given", () => {
    expect(rankFiles("lib/foo.ex", files)[0]?.path).toBe("lib/foo.ex");
  });
});

describe("exact-substring precedence", () => {
  it("ranks exact partial paths above scattered subsequence matches", () => {
    const files = [
      // "terminal/server" is a subsequence of this, scattered all over.
      "the_room_in_all/some_river.ex",
      "lib/dala/terminal/server.ex",
    ];
    const ranked = rankFiles("terminal/server", files).map((r) => r.path);
    expect(ranked[0]).toBe("lib/dala/terminal/server.ex");
  });

  it("is case-insensitive", () => {
    const ranked = rankFiles("TERMINAL/SERVER", [
      "the_room_in_all/some_river.ex",
      "lib/dala/terminal/server.ex",
    ]).map((r) => r.path);
    expect(ranked[0]).toBe("lib/dala/terminal/server.ex");
  });

  it("prefers a basename occurrence over an earlier directory hit", () => {
    // "app" occurs at index 2 (inside "snappy/") and at 7 (the basename);
    // the basename occurrence is the one users aim for.
    const match = fuzzyMatch("app", "snappy/app.ex");
    expect(match!.positions).toEqual([7, 8, 9]);
  });

  it("ranks a basename exact hit above a directory-start exact hit", () => {
    const ranked = rankFiles("app", ["app_wrapper/thing.ex", "snappy/app.ex"]).map((r) => r.path);
    expect(ranked[0]).toBe("snappy/app.ex");
  });
});

describe("display strings and highlight positions", () => {
  it("returns the original path plus an NFC display with aligned positions", () => {
    const nfd = "docs/café.md"; // decomposed é — macOS-style bytes.
    const [r] = rankFiles("café", [nfd]);
    expect(r.path).toBe(nfd); // original bytes: what the server can open
    expect(r.display).toBe(nfd.normalize("NFC"));
    // Positions are code-unit indices into `display`, not into `path`.
    expect(r.positions.map((p) => r.display[p]).join("")).toBe("café");
  });

  it("keeps positions in code-unit space for emoji filenames", () => {
    const [r] = rankFiles("rocket", ["docs/🚀rocket.md"]);
    // The rocket is 2 code units: "rocket" starts at 7, not 6.
    expect(r.positions[0]).toBe("docs/🚀".length);
    expect(r.display.slice(r.positions[0], r.positions[r.positions.length - 1] + 1)).toBe(
      "rocket",
    );
  });
});

describe("space handling", () => {
  const spaced = "strategies/选币 研究demo.py";

  it("a query without the filename's space still matches", () => {
    expect(rankFiles("选币研究", [spaced, "strategies/other.py"])[0]?.path).toBe(spaced);
  });

  it("a query with the space matches too", () => {
    expect(rankFiles("选币 研究", [spaced, "strategies/other.py"])[0]?.path).toBe(spaced);
  });

  it("a spaced query matches a space-less filename", () => {
    const ranked = rankFiles("选币 研究", ["strategies/选币研究demo.py"]);
    expect(ranked).toHaveLength(1);
  });
});
