import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Channel } from "phoenix";
import {
  createSession,
  deleteSession,
  listSessions,
  renameSession,
  setSessionGroup,
  reorderSession,
  restartSession,
} from "../../ash_rpc";
import { applyReorder, byPosition } from "../reorder";
import { getDeviceId } from "../deviceId";
import { call } from "../rpc";
import {
  createSessionsChannel,
  onSessionsChannelMessages,
  unsubscribeSessionsChannel,
} from "../../ash_typed_channels";
import type { AgentEventPayload } from "../../ash_types";
import { getSocket } from "../socket";
import type { Session } from "../Sidebar";
import { useI18n } from "../i18n";

export const SESSION_FIELDS = [
  "id",
  "name",
  "shell",
  "cwd",
  "status",
  "exitCode",
  "scrollbackLimit",
  "ephemeral",
  "group",
  "position",
  "insertedAt",
  "updatedAt",
] as const;

// COMPILE-TIME exhaustiveness guard: every field the session payload carries
// must also be fetched over RPC. A payload gains a field (like `group`) →
// this line stops compiling until SESSION_FIELDS lists it. Without it, the
// reconnect refetch silently drops the new field and state "vanishes" until
// a full page reload (that was a real bug: groups disappearing).
type _MissingSessionFields = Exclude<
  keyof Session,
  (typeof SESSION_FIELDS)[number]
>;
const _sessionFieldsComplete: _MissingSessionFields extends never
  ? true
  : never = true;
void _sessionFieldsComplete;

type Versioned = { id: string; updatedAt?: string };

/**
 * May `incoming` replace `current`? Rows carry the server's `updatedAt` as a
 * version: an out-of-order or raced broadcast can never roll a session back.
 * A missing timestamp on either side accepts the incoming copy (optimistic
 * local edits keep the old stamp on purpose, so the authoritative broadcast
 * that follows always lands).
 */
export function isFresher(
  current: Versioned | undefined,
  incoming: Versioned,
): boolean {
  if (!current?.updatedAt || !incoming.updatedAt) return true;
  // utc_datetime_usec serializes to fixed-width ISO-8601: string compare
  // IS chronological compare.
  return incoming.updatedAt >= current.updatedAt;
}

/**
 * Insert or replace a session in the list, keeping order stable on update.
 * Stale copies (older `updatedAt` than what the list holds) are dropped.
 */
export function upsertList<T extends Versioned>(list: T[], session: T): T[] {
  const idx = list.findIndex((s) => s.id === session.id);
  if (idx === -1) return [...list, session];
  if (!isFresher(list[idx], session)) return list;
  const next = [...list];
  next[idx] = session;
  return next;
}

/**
 * Reconcile a full server snapshot (initial load AND every channel rejoin)
 * with the rows already in memory:
 * - observed deletions never resurrect;
 * - rows present in both keep whichever copy is newer (`updatedAt`), so
 *   broadcasts that raced the fetch are not lost and a stale in-memory row
 *   (missed broadcasts while disconnected) is corrected;
 * - live rows absent from the snapshot survive only when they appeared
 *   during THIS fetch (creations in flight) — anything else is a ghost the
 *   server no longer knows about (deleted while we were offline).
 */
export function reconcileSnapshot<T extends Versioned>(
  snapshot: T[],
  live: T[],
  deletedIds: ReadonlySet<string>,
  arrivedInFlight: ReadonlySet<string>,
): T[] {
  let merged = snapshot.filter((session) => !deletedIds.has(session.id));
  const inSnapshot = new Set(merged.map((session) => session.id));
  for (const session of live) {
    if (deletedIds.has(session.id)) continue;
    if (inSnapshot.has(session.id)) {
      merged = upsertList(merged, session);
    } else if (arrivedInFlight.has(session.id)) {
      merged = [...merged, session];
    }
  }
  return merged;
}

/** Most recently visited session that still exists, excluding the deleted one. */
export function pickPreviousSession(
  history: string[],
  deletedId: string,
  sessions: { id: string }[],
): string | undefined {
  return [...history]
    .reverse()
    .find((h) => h !== deletedId && sessions.some((s) => s.id === h));
}

/**
 * Session list state + CRUD: the lobby channel subscription (created /
 * updated / deleted broadcasts), the initial list fetch, the active-session
 * trail and its localStorage persistence, plus quick-shell orphan cleanup.
 */
export function useSessions(opts: {
  toast: (message: string) => void;
  /** Extra handling when a session_deleted broadcast arrives (quick-shell tabs). */
  onSessionDeleted: (id: string) => void;
  /** OSC 777 agent plugin events forwarded from the lobby channel. */
  onAgentEvent: (payload: AgentEventPayload) => void;
}) {
  const { toast } = opts;
  const { t } = useI18n();
  const [sessions, setSessions] = useState<Session[]>([]);
  const [activeId, setActiveId] = useState<string | null>(
    () => localStorage.getItem("dala:active") || null,
  );
  const [connected, setConnected] = useState(false);
  const [creating, setCreating] = useState(false);
  const deletedSessionIdsRef = useRef(new Set<string>());

  // While a snapshot fetch is in flight, ids seen on the channel are
  // recorded here so reconcileSnapshot can tell an in-flight creation from
  // a ghost row the server no longer knows (see its doc).
  const fetchFlightRef = useRef<Set<string> | null>(null);

  const upsertSession = useCallback((session: Session) => {
    if (deletedSessionIdsRef.current.has(session.id)) return;
    fetchFlightRef.current?.add(session.id);
    setSessions((list) => upsertList(list, session));
  }, []);

  // Trail of visited sessions. Refs, because the channel handlers below are
  // registered once and must not see stale state.
  const activeIdRef = useRef<string | null>(null);
  const historyRef = useRef<string[]>([]);
  const sessionsRef = useRef<Session[]>([]);
  useEffect(() => {
    sessionsRef.current = sessions;
  }, [sessions]);

  // Callbacks re-read on every event so the channel handlers (registered
  // once) never call a stale closure.
  const callbacksRef = useRef(opts);
  callbacksRef.current = opts;

  // Quick shells are disposable — any ephemeral session surviving a reload
  // is a leftover, so clean it up once the first session list arrives.
  const qsCleanedRef = useRef(false);
  useEffect(() => {
    if (qsCleanedRef.current || sessions.length === 0) return;
    qsCleanedRef.current = true;
    for (const orphan of sessions.filter((s) => s.ephemeral)) {
      void call<unknown>(deleteSession, { identity: orphan.id });
    }
  }, [sessions]);

  // Socket status + sessions lobby channel.
  useEffect(() => {
    const socket = getSocket();
    const openRef = socket.onOpen(() => setConnected(true));
    const closeRef = socket.onClose(() => setConnected(false));
    setConnected(socket.isConnected());

    const channel = createSessionsChannel(socket);
    const phxChannel = channel as unknown as Channel;
    const refs = onSessionsChannelMessages(channel, {
      session_created: upsertSession,
      session_updated: upsertSession,
      agent_event: (payload) => callbacksRef.current.onAgentEvent(payload),
      session_deleted: ({ id }) => {
        deletedSessionIdsRef.current.add(id);
        setSessions((list) => list.filter((s) => s.id !== id));
        callbacksRef.current.onSessionDeleted(id);
        // The active session was deleted: return to the most recently
        // visited one that still exists.
        if (id === activeIdRef.current) {
          const previous = pickPreviousSession(
            historyRef.current,
            id,
            sessionsRef.current,
          );
          if (previous) setActiveId(previous);
        }
      },
    });
    const refetchSessions = async () => {
      // One fetch at a time: a redundant trigger (mount + the first join
      // "ok" land together) rides on the running one; broadcasts raced by
      // it are reconciled anyway.
      if (fetchFlightRef.current) return;
      const flight = new Set<string>();
      fetchFlightRef.current = flight;
      const result = await call<Session[]>(listSessions, {
        fields: [...SESSION_FIELDS],
        sort: ["position", "insertedAt"],
      });
      if (fetchFlightRef.current === flight) fetchFlightRef.current = null;
      if (result.ok) {
        setSessions((live) =>
          reconcileSnapshot(
            result.data,
            live,
            deletedSessionIdsRef.current,
            flight,
          ),
        );
      } else {
        toast(result.error || t("couldNotLoadSessions"));
      }
    };

    // The join "ok" fires on the initial join AND on every automatic
    // rejoin — refetching there heals whatever broadcasts were missed
    // while disconnected (renames from other devices used to stay stale
    // until a manual page reload).
    phxChannel.join().receive("ok", () => void refetchSessions());
    void refetchSessions();

    return () => {
      unsubscribeSessionsChannel(channel, refs);
      phxChannel.leave();
      socket.off([openRef, closeRef]);
    };
  }, [toast, upsertSession, t]);

  // Quick shells (ephemeral) live in their overlay panel, not the sidebar
  // or the active-session rotation. Sort by the server-persisted position
  // (insertedAt on ties) so all devices agree on the sidebar order.
  const ordered = useMemo(
    () => [...sessions].filter((s) => !s.ephemeral).sort(byPosition),
    [sessions],
  );
  const active = ordered.find((s) => s.id === activeId) ?? ordered[0] ?? null;

  useEffect(() => {
    if (!active) return;
    localStorage.setItem("dala:active", active.id);
    activeIdRef.current = active.id;
    const trail = historyRef.current.filter((id) => id !== active.id);
    trail.push(active.id);
    historyRef.current = trail.slice(-20);
  }, [active?.id]);

  /** Create a session and make it active; resolves to it (null on failure). */
  const handleCreate = async (
    input: { cwd?: string; ephemeral?: boolean } = {},
  ): Promise<Session | null> => {
    setCreating(true);
    // deviceId stamps THIS device as the session's size owner at creation:
    // an idle tab elsewhere that auto-mounts the new session can no longer
    // win the first-attach adoption race (the creating phone stays owner).
    const result = await call<Session>(createSession, {
      input: { ...input, deviceId: getDeviceId() },
      fields: [...SESSION_FIELDS],
    });
    setCreating(false);
    if (result.ok) {
      const session = result.data;
      upsertSession(session);
      setActiveId(session.id);
      return session;
    }
    toast(result.error || t("couldNotCreateTerminal"));
    return null;
  };

  /** Restart the shell of an exited session; resolves to true on success. */
  const handleRestart = async (id: string): Promise<boolean> => {
    const result = await call<unknown>(restartSession, { input: { id } });
    if (!result.ok) {
      toast(result.error || t("couldNotRestart"));
      return false;
    }
    return true;
  };

  /**
   * Move a session before another (null = to the end): optimistic local
   * position (mirroring the server's midpoint math), rolled back on error.
   * The session_updated broadcast then carries the authoritative position.
   */
  const handleReorder = async (id: string, beforeId: string | null) => {
    const previous = sessionsRef.current.find((s) => s.id === id)?.position;
    if (previous === undefined) return;
    setSessions((list) => applyReorder(list, id, beforeId));
    const result = await call<unknown>(reorderSession, {
      identity: id,
      input: beforeId === null ? {} : { beforeId },
    });
    if (!result.ok) {
      setSessions((list) =>
        list.map((s) => (s.id === id ? { ...s, position: previous } : s)),
      );
      toast(result.error || t("somethingWentWrong"));
    }
  };

  /**
   * Rename a session: optimistic local name, rolled back on error (same
   * shape as the reorder above). The session_updated broadcast then carries
   * the authoritative name to every device.
   */
  const handleRename = async (id: string, name: string) => {
    const previous = sessionsRef.current.find((s) => s.id === id)?.name;
    if (previous === undefined || previous === name) return;
    setSessions((list) => list.map((s) => (s.id === id ? { ...s, name } : s)));
    const result = await call<unknown>(renameSession, {
      identity: id,
      input: { name },
    });
    if (!result.ok) {
      setSessions((list) =>
        list.map((s) => (s.id === id ? { ...s, name: previous } : s)),
      );
      toast(result.error || t("somethingWentWrong"));
    }
  };

  /**
   * Assign sessions to a group (null = ungroup): optimistic like rename,
   * rolled back per-session on error; broadcasts sync other devices.
   */
  const handleSetGroup = async (ids: string[], group: string | null) => {
    const previous = new Map(
      sessionsRef.current
        .filter((s) => ids.includes(s.id))
        .map((s) => [s.id, s.group]),
    );
    setSessions((list) =>
      list.map((s) => (previous.has(s.id) ? { ...s, group } : s)),
    );
    const results = await Promise.all(
      ids.map(async (id) => ({
        id,
        result: await call<unknown>(setSessionGroup, {
          identity: id,
          input: { group },
        }),
      })),
    );
    const failed = results.filter((r) => !r.result.ok);
    if (failed.length > 0) {
      setSessions((list) =>
        list.map((s) =>
          failed.some((f) => f.id === s.id)
            ? { ...s, group: previous.get(s.id) ?? null }
            : s,
        ),
      );
      toast(
        failed[0].result.ok
          ? t("somethingWentWrong")
          : failed[0].result.error || t("somethingWentWrong"),
      );
    }
  };

  const deleting = useRef(new Set<string>());
  const handleDelete = async (id: string) => {
    if (deleting.current.has(id)) return;
    deleting.current.add(id);
    try {
      const result = await call<unknown>(deleteSession, { identity: id });
      if (result.ok) {
        deletedSessionIdsRef.current.add(id);
        setSessions((list) => list.filter((s) => s.id !== id));
        if (activeId === id) setActiveId(null);
      } else {
        toast(result.error || t("somethingWentWrong"));
      }
    } finally {
      deleting.current.delete(id);
    }
  };

  return {
    sessions,
    setSessions,
    upsertSession,
    ordered,
    active,
    activeId,
    setActiveId,
    connected,
    creating,
    activeIdRef,
    sessionsRef,
    handleCreate,
    handleRestart,
    handleDelete,
    handleReorder,
    handleRename,
    handleSetGroup,
  };
}
