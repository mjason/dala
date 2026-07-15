import { describe, expect, it } from "vitest";
import {
  mergeInitialSessions,
  pickPreviousSession,
  upsertList,
} from "./useSessions";
import type { Session } from "../Sidebar";

type Row = { id: string; name: string };

const session = (id: string, name = id): Session =>
  ({
    id,
    name,
    shell: "/bin/bash",
    cwd: "/tmp",
    status: "running",
    exitCode: null,
    scrollbackLimit: 10_000,
    ephemeral: false,
    insertedAt: "2026-01-01T00:00:00Z",
  }) as Session;

describe("upsertList", () => {
  it("appends a new session at the end", () => {
    const list = [session("a")];
    const next = upsertList(list, session("b"));
    expect(next.map((s) => s.id)).toEqual(["a", "b"]);
    expect(list).toHaveLength(1); // input untouched
  });

  it("replaces an existing session in place, keeping order", () => {
    const list = [session("a"), session("b", "old"), session("c")];
    const next = upsertList(list, session("b", "new"));
    expect(next.map((s) => s.id)).toEqual(["a", "b", "c"]);
    expect(next[1].name).toBe("new");
  });
});

describe("pickPreviousSession", () => {
  const live = [session("a"), session("b"), session("c")];

  it("returns the most recently visited surviving session", () => {
    expect(pickPreviousSession(["a", "b", "c"], "c", live)).toBe("b");
  });

  it("skips the deleted id even when it is elsewhere in the trail", () => {
    expect(pickPreviousSession(["c", "a", "c"], "c", live)).toBe("a");
  });

  it("skips sessions that no longer exist", () => {
    expect(pickPreviousSession(["gone", "a"], "x", live)).toBe("a");
    expect(pickPreviousSession(["gone"], "x", live)).toBeUndefined();
  });

  it("does not mutate the history trail", () => {
    const history = ["a", "b"];
    pickPreviousSession(history, "b", live);
    expect(history).toEqual(["a", "b"]);
  });
});

describe("mergeInitialSessions", () => {
  it("keeps a session created while the initial snapshot was loading", () => {
    const snapshot: Row[] = [{ id: "old", name: "old" }];
    const live: Row[] = [
      { id: "old", name: "renamed-live" },
      { id: "new", name: "new" },
    ];

    expect(mergeInitialSessions(snapshot, live, new Set())).toEqual([
      { id: "old", name: "renamed-live" },
      { id: "new", name: "new" },
    ]);
  });

  it("does not resurrect a session deleted while the snapshot was loading", () => {
    const snapshot: Row[] = [
      { id: "kept", name: "kept" },
      { id: "deleted", name: "stale" },
    ];

    expect(mergeInitialSessions(snapshot, [], new Set(["deleted"]))).toEqual([
      { id: "kept", name: "kept" },
    ]);
  });
});
