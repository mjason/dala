import { describe, expect, it } from "vitest";
import {
  isFresher,
  pickPreviousSession,
  reconcileSnapshot,
  upsertList,
} from "./useSessions";
import type { Session } from "../Sidebar";

const session = (id: string, name = id, updatedAt = "2026-01-01T00:00:00.000000Z"): Session =>
  ({
    id,
    name,
    shell: "/bin/bash",
    cwd: "/tmp",
    status: "running",
    exitCode: null,
    scrollbackLimit: 10_000,
    ephemeral: false,
    insertedAt: "2026-01-01T00:00:00.000000Z",
    updatedAt,
  }) as Session;

const T1 = "2026-01-01T00:00:01.000000Z";
const T2 = "2026-01-01T00:00:02.000000Z";

describe("isFresher (row versions)", () => {
  it("newer or equal updatedAt may replace; older may not", () => {
    expect(isFresher(session("a", "a", T1), session("a", "a", T2))).toBe(true);
    expect(isFresher(session("a", "a", T1), session("a", "a", T1))).toBe(true);
    expect(isFresher(session("a", "a", T2), session("a", "a", T1))).toBe(false);
  });

  it("a missing timestamp on either side accepts the incoming copy", () => {
    const unstamped = { id: "a" };
    expect(isFresher(unstamped, session("a"))).toBe(true);
    expect(isFresher(session("a"), unstamped)).toBe(true);
    expect(isFresher(undefined, session("a"))).toBe(true);
  });
});

describe("upsertList", () => {
  it("appends a new session at the end", () => {
    const list = [session("a")];
    const next = upsertList(list, session("b"));
    expect(next.map((s) => s.id)).toEqual(["a", "b"]);
    expect(list).toHaveLength(1); // input untouched
  });

  it("replaces an existing session in place, keeping order", () => {
    const list = [session("a"), session("b", "old", T1), session("c")];
    const next = upsertList(list, session("b", "new", T2));
    expect(next.map((s) => s.id)).toEqual(["a", "b", "c"]);
    expect(next[1].name).toBe("new");
  });

  it("drops a STALE copy — the named regression: a cwd/status broadcast built from an old row must not roll back a rename", () => {
    const list = [session("a", "renamed", T2)];
    const next = upsertList(list, session("a", "old-name", T1));
    expect(next[0].name).toBe("renamed");
    expect(next).toBe(list); // untouched, no re-render churn
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

describe("reconcileSnapshot (initial load AND rejoin refetch)", () => {
  const none = new Set<string>();

  it("keeps a session created while the snapshot was loading", () => {
    const snapshot = [session("old")];
    const live = [session("old", "renamed-live", T2), session("new")];

    const merged = reconcileSnapshot(snapshot, live, none, new Set(["new"]));
    expect(merged.map((s) => s.id)).toEqual(["old", "new"]);
    expect(merged[0].name).toBe("renamed-live");
  });

  it("does not resurrect a session deleted while the snapshot was loading", () => {
    const snapshot = [session("kept"), session("deleted", "stale")];

    expect(
      reconcileSnapshot(snapshot, [], new Set(["deleted"]), none).map((s) => s.id),
    ).toEqual(["kept"]);
  });

  it("rejoin: the snapshot corrects rows that went stale while offline", () => {
    // A rename from another device happened while we were disconnected —
    // the in-memory row is old, the snapshot is truth.
    const live = [session("a", "stale-name", T1)];
    const snapshot = [session("a", "renamed-elsewhere", T2)];

    const merged = reconcileSnapshot(snapshot, live, none, none);
    expect(merged[0].name).toBe("renamed-elsewhere");
  });

  it("rejoin: a broadcast that raced the fetch still wins over the snapshot", () => {
    const snapshot = [session("a", "snapshot-copy", T1)];
    const live = [session("a", "broadcast-during-fetch", T2)];

    const merged = reconcileSnapshot(snapshot, live, none, none);
    expect(merged[0].name).toBe("broadcast-during-fetch");
  });

  it("rejoin: ghost rows (deleted while offline, no broadcast seen) are dropped", () => {
    const live = [session("a"), session("ghost")];
    const snapshot = [session("a")];

    expect(reconcileSnapshot(snapshot, live, none, none).map((s) => s.id)).toEqual(["a"]);
  });
});
