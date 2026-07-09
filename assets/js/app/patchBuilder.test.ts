import { describe, expect, it } from "vitest";
import { buildChunkPatch, buildLinesPatch } from "./patchBuilder";

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

describe("buildLinesPatch", () => {
  // Chunk replaces lines 4-5 ("four", "five") with "FOUR!", "FIVE!", "extra".
  const oldDoc = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
  const newDoc = "one\ntwo\nthree\nFOUR!\nFIVE!\nextra\nsix\nseven\n";
  const chunk = { fromA: 4, toA: 6, fromB: 4, toB: 7 };

  it("stages only the selected lines; the rest stays as context or is dropped", () => {
    // Select removal of "four" and addition of "FOUR!" — leave five/FIVE!/extra.
    const patch = buildLinesPatch("a.txt", oldDoc, newDoc, chunk, {
      removed: new Set([0]),
      added: new Set([0]),
    });

    expect(patch).toBe(
      [
        "diff --git a/a.txt b/a.txt",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1,7 +1,7 @@",
        " one",
        " two",
        " three",
        "-four",
        "+FOUR!", // additions land right after the removal they replace
        " five", // unselected removal → context
        " six",
        " seven",
        "",
      ].join("\n"),
    );
    // Unselected additions are dropped entirely.
    expect(patch).not.toContain("FIVE!");
    expect(patch).not.toContain("extra");
  });

  it("reverse builds the undo patch against the new document", () => {
    // Discard the "extra" addition only.
    const patch = buildLinesPatch(
      "a.txt",
      oldDoc,
      newDoc,
      chunk,
      { removed: new Set(), added: new Set([2]) },
      { reverse: true },
    );

    expect(patch).toBe(
      [
        "diff --git a/a.txt b/a.txt",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1,8 +1,7 @@",
        " one",
        " two",
        " three",
        " FOUR!", // unselected additions stay as context in the new doc
        " FIVE!",
        "-extra",
        " six",
        " seven",
        "",
      ].join("\n"),
    );
  });

  it("reverse restores selected removals into the new document", () => {
    const patch = buildLinesPatch(
      "a.txt",
      oldDoc,
      newDoc,
      chunk,
      { removed: new Set([1]), added: new Set() },
      { reverse: true },
    );
    // "five" was removed from the file; discarding that removal re-adds it.
    expect(patch).toContain("+five");
    expect(patch).not.toContain("-five");
    expect(patch).toContain("@@ -1,8 +1,9 @@");
  });

  it("selecting everything matches the full chunk patch semantics", () => {
    const patch = buildLinesPatch("a.txt", oldDoc, newDoc, chunk, {
      removed: new Set([0, 1]),
      added: new Set([0, 1, 2]),
    });
    expect(patch).toContain("-four");
    expect(patch).toContain("-five");
    expect(patch).toContain("+FOUR!");
    expect(patch).toContain("+FIVE!");
    expect(patch).toContain("+extra");
    expect(patch).toContain("@@ -1,7 +1,8 @@");
  });

  it("handles a selection in a pure insertion at the end of the file", () => {
    const patch = buildLinesPatch(
      "a.txt",
      "one\ntwo\n",
      "one\ntwo\nthree\nfour\n",
      { fromA: 3, toA: 3, fromB: 3, toB: 5 },
      { removed: new Set(), added: new Set([1]) },
    );
    expect(patch).toContain("@@ -1,2 +1,3 @@");
    expect(patch).toContain("+four");
    expect(patch).not.toContain("three");
  });
});
