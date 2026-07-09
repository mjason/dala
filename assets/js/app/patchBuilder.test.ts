import { describe, expect, it } from "vitest";
import { buildChunkPatch } from "./patchBuilder";

const oldText = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
const newText = "one\ntwo\nthree\nFOUR!\nfive\nsix\nseven\n";

describe("buildChunkPatch", () => {
  it("builds a forward patch for a modified line with context", () => {
    const patch = buildChunkPatch("src/a.txt", oldText, newText, {
      fromA: 4,
      toA: 5,
      fromB: 4,
      toB: 5,
    });

    expect(patch).toBe(
      [
        "diff --git a/src/a.txt b/src/a.txt",
        "--- a/src/a.txt",
        "+++ b/src/a.txt",
        "@@ -1,7 +1,7 @@",
        " one",
        " two",
        " three",
        "-four",
        "+FOUR!",
        " five",
        " six",
        " seven",
        "",
      ].join("\n"),
    );
  });

  it("reverse swaps the sides (undo direction)", () => {
    const patch = buildChunkPatch(
      "a.txt",
      oldText,
      newText,
      { fromA: 4, toA: 5, fromB: 4, toB: 5 },
      { reverse: true },
    );
    expect(patch).toContain("-FOUR!");
    expect(patch).toContain("+four");
  });

  it("handles pure insertions at the end of the file", () => {
    const patch = buildChunkPatch("a.txt", "one\ntwo\n", "one\ntwo\nthree\n", {
      fromA: 3,
      toA: 3,
      fromB: 3,
      toB: 4,
    });
    expect(patch).toContain("@@ -1,2 +1,3 @@");
    expect(patch).toContain(" two");
    expect(patch).toContain("+three");
    expect(patch).not.toMatch(/^-[^-]/m);
  });

  it("handles pure deletions", () => {
    const patch = buildChunkPatch("a.txt", "one\ntwo\nthree\n", "one\nthree\n", {
      fromA: 2,
      toA: 3,
      fromB: 2,
      toB: 2,
    });
    expect(patch).toContain("-two");
    expect(patch).toContain("@@ -1,3 +1,2 @@");
  });

  it("clamps context at the start of the file", () => {
    const patch = buildChunkPatch("a.txt", "one\ntwo\n", "ONE\ntwo\n", {
      fromA: 1,
      toA: 2,
      fromB: 1,
      toB: 2,
    });
    expect(patch).toContain("@@ -1,2 +1,2 @@");
    expect(patch).toContain("-one");
    expect(patch).toContain("+ONE");
  });
});
