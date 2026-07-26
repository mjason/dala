import { describe, expect, it } from "vitest";
import type { Session } from "./Sidebar";
import {
  attachedCount,
  rootIdOf,
  rootSessions,
  tabAfterClose,
  tabsFor,
} from "./shellTabs";

function session(id: string, over: Partial<Session> = {}): Session {
  return {
    id,
    name: id,
    shell: "/bin/bash",
    cwd: "/home/mj",
    status: "running",
    exitCode: null,
    scrollbackLimit: 10_000,
    ephemeral: false,
    parentId: null,
    group: null,
    position: 1,
    insertedAt: "2026-07-26T00:00:00Z",
    updatedAt: "2026-07-26T00:00:00Z",
    ...over,
  } as Session;
}

describe("sessionTabs", () => {
  const root = session("root");
  const other = session("other", { position: 2 });
  const first = session("first", { parentId: "root", position: 3 });
  const second = session("second", { parentId: "root", position: 4 });
  const all = [root, other, first, second];

  it("keeps attached shells out of the sidebar", () => {
    expect(rootSessions(all).map((s) => s.id)).toEqual(["root", "other"]);
  });

  it("maps a tab back to the sidebar row that owns it", () => {
    expect(rootIdOf(all, "second")).toBe("root");
    expect(rootIdOf(all, "root")).toBe("root");
    expect(rootIdOf(all, null)).toBeNull();
  });

  it("treats an unknown id as its own root, so a mid-delete render is stable", () => {
    expect(rootIdOf(all, "vanished")).toBe("vanished");
  });

  it("puts the main shell first and the attached shells in creation order", () => {
    expect(tabsFor(all, "root").map((s) => s.id)).toEqual(["root", "first", "second"]);
  });

  it("orders equal positions by creation time", () => {
    const a = session("a", { parentId: "root", position: 3, insertedAt: "2026-07-26T00:00:02Z" });
    const b = session("b", { parentId: "root", position: 3, insertedAt: "2026-07-26T00:00:01Z" });

    expect(tabsFor([root, a, b], "root").map((s) => s.id)).toEqual(["root", "b", "a"]);
  });

  it("has no tabs for an unknown root, or for a session that is itself a tab", () => {
    expect(tabsFor(all, "vanished")).toEqual([]);
    expect(tabsFor(all, "first")).toEqual([]);
    expect(tabsFor(all, null)).toEqual([]);
  });

  it("counts attached shells for the sidebar badge", () => {
    expect(attachedCount(all, "root")).toBe(2);
    expect(attachedCount(all, "other")).toBe(0);
  });

  describe("what to show after closing a tab", () => {
    it("returns to the parent, not to whatever was visited more recently", () => {
      expect(tabAfterClose(all, "second", "other")).toBe("root");
    });

    it("falls back to the MRU session when a plain session is closed", () => {
      expect(tabAfterClose(all, "other", "root")).toBe("root");
    });

    it("falls back to the MRU session when the parent is gone too", () => {
      const orphan = session("orphan", { parentId: "gone" });
      expect(tabAfterClose([orphan, other], "orphan", "other")).toBe("other");
    });

    it("has nothing to offer when nothing is left", () => {
      expect(tabAfterClose(all, "other", undefined)).toBeUndefined();
    });
  });
});
