import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Channel } from "phoenix";
import {
  createSession,
  deleteSession,
  listSessions,
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
  "position",
  "insertedAt",
] as const;

/** Insert or replace a session in the list, keeping order stable on update. */
export function upsertList(list: Session[], session: Session): Session[] {
  const idx = list.findIndex((s) => s.id === session.id);
  if (idx === -1) return [...list, session];
  const next = [...list];
  next[idx] = session;
  return next;
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

  const upsertSession = useCallback((session: Session) => {
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
        setSessions((list) => list.filter((s) => s.id !== id));
        callbacksRef.current.onSessionDeleted(id);
        // The active session was deleted: return to the most recently
        // visited one that still exists.
        if (id === activeIdRef.current) {
          const previous = pickPreviousSession(historyRef.current, id, sessionsRef.current);
          if (previous) setActiveId(previous);
        }
      },
    });
    phxChannel.join();

    void (async () => {
      const result = await call<Session[]>(listSessions, {
        fields: [...SESSION_FIELDS],
        sort: ["position", "insertedAt"],
      });
      if (result.ok) {
        setSessions(result.data);
      } else {
        toast(result.error || t("couldNotLoadSessions"));
      }
    })();

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

  const deleting = useRef(new Set<string>());
  const handleDelete = async (id: string) => {
    if (deleting.current.has(id)) return;
    deleting.current.add(id);
    try {
      const result = await call<unknown>(deleteSession, { identity: id });
      if (result.ok) {
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
  };
}
