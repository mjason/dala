import { describe, expect, it } from "vitest";
import { groupSessions, rangeBetween } from "./sessionGroups";

const s = (id: string, cwd: string) => ({ id, cwd });

describe("groupSessions", () => {
  it("groups by cwd at first appearance, keeping in-group order", () => {
    const groups = groupSessions([
      s("a", "/p/alpha"),
      s("b", "/p/beta"),
      s("c", "/p/alpha"),
      s("d", "/p/beta"),
    ]);
    expect(groups.map((g) => g.key)).toEqual(["/p/alpha", "/p/beta"]);
    expect(groups[0].sessions.map((x) => x.id)).toEqual(["a", "c"]);
    expect(groups[1].sessions.map((x) => x.id)).toEqual(["b", "d"]);
  });

  it("labels groups by directory basename", () => {
    const [g] = groupSessions([s("a", "/home/mj/dev/elixir/dala")]);
    expect(g.label).toBe("dala");
    const [root] = groupSessions([s("b", "/")]);
    expect(root.label).toBe("/");
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
