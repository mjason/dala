import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Channel } from "phoenix";
import { buildCSRFHeaders, createSession, listSessions, restartSession } from "../ash_rpc";
import {
  createSessionsChannel,
  onSessionsChannelMessages,
  unsubscribeSessionsChannel,
} from "../ash_typed_channels";
import { getSocket } from "./socket";
import Sidebar, { Session } from "./Sidebar";
import TerminalView from "./TerminalView";
import FileDrawer from "./FileDrawer";
import SettingsModal from "./SettingsModal";
import { shortPath } from "./util";

const SESSION_FIELDS = [
  "id",
  "name",
  "shell",
  "cwd",
  "status",
  "exitCode",
  "scrollbackLimit",
  "insertedAt",
] as const;

type Toast = { id: number; message: string };

export default function App() {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [activeId, setActiveId] = useState<string | null>(
    () => localStorage.getItem("dala:active") || null,
  );
  const [connected, setConnected] = useState(false);
  const [creating, setCreating] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [drawerPath, setDrawerPath] = useState<string | null>(null);
  const [followCwd, setFollowCwd] = useState(true);
  const [settingsFor, setSettingsFor] = useState<string | null>(null);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastSeq = useRef(0);

  const toast = useCallback((message: string) => {
    const id = ++toastSeq.current;
    setToasts((t) => [...t, { id, message }]);
    window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 5000);
  }, []);

  const upsertSession = useCallback((session: Session) => {
    setSessions((list) => {
      const idx = list.findIndex((s) => s.id === session.id);
      if (idx === -1) return [...list, session];
      const next = [...list];
      next[idx] = session;
      return next;
    });
  }, []);

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
      session_deleted: ({ id }) => setSessions((list) => list.filter((s) => s.id !== id)),
    });
    phxChannel.join();

    void (async () => {
      const result = await listSessions({
        fields: [...SESSION_FIELDS],
        sort: "insertedAt",
        headers: buildCSRFHeaders(),
      });
      if (result.success) {
        setSessions(result.data as unknown as Session[]);
      } else {
        toast(result.errors[0]?.message ?? "Could not load sessions");
      }
    })();

    return () => {
      unsubscribeSessionsChannel(channel, refs);
      phxChannel.leave();
      socket.off([openRef, closeRef]);
    };
  }, [toast, upsertSession]);

  const ordered = useMemo(
    () => [...sessions].sort((a, b) => a.insertedAt.localeCompare(b.insertedAt)),
    [sessions],
  );
  const active = ordered.find((s) => s.id === activeId) ?? ordered[0] ?? null;

  useEffect(() => {
    if (active) localStorage.setItem("dala:active", active.id);
  }, [active?.id]);

  // Keep the drawer on the terminal's cwd while following.
  useEffect(() => {
    if (followCwd && active) setDrawerPath(active.cwd);
  }, [followCwd, active?.id, active?.cwd]);

  const handleCreate = async () => {
    setCreating(true);
    const result = await createSession({
      input: {},
      fields: [...SESSION_FIELDS],
      headers: buildCSRFHeaders(),
    });
    setCreating(false);
    if (result.success) {
      const session = result.data as unknown as Session;
      upsertSession(session);
      setActiveId(session.id);
    } else {
      toast(result.errors[0]?.message ?? "Could not create terminal");
    }
  };

  const handleRestart = async (id: string) => {
    const result = await restartSession({
      input: { id },
      headers: buildCSRFHeaders(),
    });
    if (!result.success) toast(result.errors[0]?.message ?? "Could not restart");
  };

  const settingsSession = ordered.find((s) => s.id === settingsFor) ?? null;

  return (
    <div className="flex h-full w-full overflow-hidden bg-bg0 text-fg">
      <Sidebar
        sessions={ordered}
        activeId={active?.id ?? null}
        connected={connected}
        creating={creating}
        onSelect={setActiveId}
        onCreate={() => void handleCreate()}
        onOpenSettings={setSettingsFor}
      />

      <main className="flex min-w-0 flex-1 flex-col">
        {active ? (
          <>
            <header className="flex h-10 shrink-0 items-center gap-3 border-b border-line bg-bg1 px-4">
              <span className="font-mono text-[13px] text-fg">{active.name}</span>
              <span className="truncate font-mono text-[11px] text-fg-muted" title={active.cwd}>
                {shortPath(active.cwd, 60)}
              </span>
              <div className="flex-1" />
              <span
                className={`font-mono text-[10px] ${
                  active.status === "running" ? "text-mint" : "text-fg-muted"
                }`}
              >
                {active.status === "running"
                  ? "running"
                  : `exited${active.exitCode != null ? ` (${active.exitCode})` : ""}`}
              </span>
              <button
                id="toggle-drawer-button"
                onClick={() => setDrawerOpen((v) => !v)}
                className={`rounded-md border px-2 py-1 font-mono text-[10px] transition-colors ${
                  drawerOpen
                    ? "border-mint/50 text-mint"
                    : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
                }`}
                title="Toggle file drawer"
              >
                files
              </button>
              <button
                onClick={() => setSettingsFor(active.id)}
                className="rounded-md border border-line px-2 py-1 font-mono text-[10px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg"
              >
                settings
              </button>
            </header>

            <div className="relative min-h-0 flex-1 bg-[#0b0c0e]">
              <TerminalView
                key={active.id}
                sessionId={active.id}
                onCwdChange={(cwd) => {
                  if (followCwd) setDrawerPath(cwd);
                }}
              />
              {active.status === "exited" && (
                <div className="absolute inset-0 grid place-items-center bg-bg0/70 backdrop-blur-[1px]">
                  <div className="flex flex-col items-center gap-3 rounded-xl border border-line bg-bg1 px-8 py-6 shadow-2xl">
                    <span className="font-mono text-xs text-fg-muted">
                      shell exited{active.exitCode != null ? ` with code ${active.exitCode}` : ""}
                    </span>
                    <button
                      id="overlay-restart-button"
                      onClick={() => void handleRestart(active.id)}
                      className="rounded-md bg-mint px-4 py-1.5 text-xs font-medium text-black transition-colors hover:brightness-110"
                    >
                      Restart shell
                    </button>
                  </div>
                </div>
              )}
            </div>
          </>
        ) : (
          <div className="grid flex-1 place-items-center">
            <div className="flex flex-col items-center gap-4">
              <pre className="font-mono text-[11px] leading-4 text-fg-muted/70 select-none">{`
 ██████   █████  ██      █████
 ██   ██ ██   ██ ██     ██   ██
 ██   ██ ███████ ██     ███████
 ██████  ██   ██ ██████ ██   ██`}</pre>
              <p className="text-xs text-fg-muted">A terminal that survives your refresh.</p>
              <button
                onClick={() => void handleCreate()}
                disabled={creating}
                className="rounded-md bg-mint px-4 py-1.5 text-xs font-medium text-black transition-colors hover:brightness-110 disabled:opacity-50"
              >
                New terminal
              </button>
            </div>
          </div>
        )}
      </main>

      {drawerOpen && active && (
        <FileDrawer
          path={drawerPath ?? active.cwd}
          followCwd={followCwd}
          onNavigate={(p) => {
            setFollowCwd(false);
            setDrawerPath(p);
          }}
          onToggleFollow={() => setFollowCwd((v) => !v)}
          onClose={() => setDrawerOpen(false)}
          onError={toast}
        />
      )}

      {settingsSession && (
        <SettingsModal
          session={settingsSession}
          onClose={() => setSettingsFor(null)}
          onDeleted={() => {
            setSessions((list) => list.filter((s) => s.id !== settingsSession.id));
            if (activeId === settingsSession.id) setActiveId(null);
          }}
          onError={toast}
        />
      )}

      <div className="pointer-events-none fixed bottom-4 right-4 z-50 flex flex-col gap-2">
        {toasts.map((t) => (
          <div
            key={t.id}
            className="pointer-events-auto rounded-lg border border-danger/40 bg-bg1 px-3 py-2 text-xs text-fg shadow-xl"
          >
            {t.message}
          </div>
        ))}
      </div>
    </div>
  );
}
