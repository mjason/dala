import { describe, expect, it } from "vitest";
import { groupNames, groupSessions, rangeBetween } from "./sessionGroups";

const s = (id: string, group: string | null = null) => ({ id, group });

describe("groupSessions", () => {
  it("clusters by manual group at first appearance, keeping in-group order", () => {
    const groups = groupSessions([s("a", "work"), s("b", "play"), s("c", "work"), s("d", "play")]);
    expect(groups.map((g) => g.key)).toEqual(["work", "play"]);
    expect(groups[0].sessions.map((x) => x.id)).toEqual(["a", "c"]);
    expect(groups[1].sessions.map((x) => x.id)).toEqual(["b", "d"]);
  });

  it("keeps a header for a single-member named group", () => {
    const groups = groupSessions([s("a", "solo")]);
    expect(groups).toHaveLength(1);
    expect(groups[0].key).toBe("solo");
  });

  it("runs of ungrouped rows form anonymous pseudo-groups between named ones", () => {
    const groups = groupSessions([s("a"), s("b"), s("c", "work"), s("d")]);
    expect(groups.map((g) => g.key)).toEqual([null, "work", null]);
    expect(groups[0].sessions.map((x) => x.id)).toEqual(["a", "b"]);
    expect(groups[2].sessions.map((x) => x.id)).toEqual(["d"]);
  });
});

describe("groupNames", () => {
  it("lists distinct names in order", () => {
    expect(groupNames([s("a", "work"), s("b"), s("c", "play"), s("d", "work")])).toEqual([
      "work",
      "play",
    ]);
  });
});

describe("rangeBetween", () => {
  const ids = ["a", "b", "c", "d", "e"];

  it("returns the inclusive range in either direction", () => {
    expect(rangeBetween(ids, "b", "d")).toEqual(["b", "c", "d"]);
    expect(rangeBetween(ids, "d", "b")).toEqual(["b", "c", "d"]);
  });

  it("falls back to the target when the anchor is gone", () => {
    expect(rangeBetween(ids, "zz", "c")).toEqual(["c"]);
  });
});
