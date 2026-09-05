import { describe, expect, it } from "vitest";
import { buildGraphRows } from "./HistoryView";
import type { Commit } from "./types";

const commit = (hash: string, parents: string[] = []): Commit => ({
  hash,
  parents,
  author: "Dala Test",
  date: "2026-01-01T00:00:00Z",
  subject: hash,
});

describe("commit graph lanes", () => {
  it("keeps a linear history in one lane", () => {
    const rows = buildGraphRows([
      commit("c", ["b"]),
      commit("b", ["a"]),
      commit("a"),
    ]);

    expect(rows.map((row) => row.lane)).toEqual([0, 0, 0]);
    expect(rows[0].targets).toEqual([0]);
  });

  it("fans merge parents into separate lanes and joins an existing lane", () => {
    const rows = buildGraphRows([
      commit("merge", ["main", "side"]),
      commit("side", ["base"]),
      commit("main", ["base"]),
      commit("base"),
    ]);

    expect(rows[0]).toMatchObject({ lane: 0, targets: [0, 1], width: 2 });
    expect(rows[1].lane).toBe(1);
    expect(rows[2].lane).toBe(0);
    expect(rows[3].lane).toBe(0);
  });
});
