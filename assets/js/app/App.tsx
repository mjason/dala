import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Channel } from "phoenix";
import {
  buildCSRFHeaders,
  createSession,
  deleteSession,
  listSessions,
  restartSession,
} from "../ash_rpc";
import {
  createSessionsChannel,
  onSessionsChannelMessages,
  unsubscribeSessionsChannel,
} from "../ash_typed_channels";
import { getSocket } from "./socket";
import Sidebar, { Session } from "./Sidebar";
import TerminalView from "./TerminalView";
import FileDrawer from "./FileDrawer";
import GitPanel from "./GitPanel";
import SettingsModal from "./SettingsModal";
import QuickOpen from "./QuickOpen";
import FilePreview, { type Preview } from "./FilePreview";
import { loadPreview } from "./loadPreview";
import { isMac, Kbd, modShiftCombo, Tooltip } from "./shortcuts";
import { shortPath } from "./util";
import { useI18n } from "./i18n";

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
  const { t } = useI18n();
  const [sessions, setSessions] = useState<Session[]>([]);
  const [activeId, setActiveId] = useState<string | null>(
    () => localStorage.getItem("dala:active") || null,
  );
  const [connected, setConnected] = useState(false);
  const [creating, setCreating] = useState(false);
  const [navOpen, setNavOpen] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [gitOpen, setGitOpen] = useState(false);
  const [drawerPath, setDrawerPath] = useState<string | null>(null);
  const [followCwd, setFollowCwd] = useState(true);
  const [settingsFor, setSettingsFor] = useState<string | null>(null);
  const [deleteFor, setDeleteFor] = useState<string | null>(null);
  const [quickOpen, setQuickOpen] = useState(false);
  const [quickPreview, setQuickPreview] = useState<Preview | null>(null);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastSeq = useRef(0);
  const termActions = useRef<{ reset: () => void; refit: () => void } | null>(null);

  const toast = useCallback((message: string) => {
    const id = ++toastSeq.current;
    setToasts((list) => [...list, { id, message }]);
    window.setTimeout(() => setToasts((list) => list.filter((x) => x.id !== id)), 5000);
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
        toast(result.errors[0]?.message ?? t("couldNotLoadSessions"));
      }
    })();

    return () => {
      unsubscribeSessionsChannel(channel, refs);
      phxChannel.leave();
      socket.off([openRef, closeRef]);
    };
  }, [toast, upsertSession, t]);

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
      setNavOpen(false);
    } else {
      toast(result.errors[0]?.message ?? t("couldNotCreateTerminal"));
    }
  };

  const handleRestart = async (id: string) => {
    const result = await restartSession({
      input: { id },
      headers: buildCSRFHeaders(),
    });
    if (!result.success) {
      toast(result.errors[0]?.message ?? t("couldNotRestart"));
      return;
    }
    // The revived shell is a fresh PTY at the default size — push our real size
    // immediately instead of waiting for a resize event.
    termActions.current?.refit();
    window.setTimeout(() => termActions.current?.refit(), 200);
  };

  // Global header shortcuts. Ctrl+Shift/⌘ combos never type into the shell,
  // so they work even while the terminal has focus; plain Ctrl+P inside the
  // terminal stays with readline (previous-history), while ⌘P on macOS is
  // always ours.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
      const key = e.key.toLowerCase();

      if (!e.shiftKey && key === "p") {
        const inTerminal = (e.target as HTMLElement | null)?.closest?.(".xterm");
        if (inTerminal && !e.metaKey) return;
        e.preventDefault();
        setQuickOpen(true);
        return;
      }

      if (e.shiftKey) {
        switch (key) {
          case "e":
            e.preventDefault();
            setDrawerOpen((v) => !v);
            setGitOpen(false);
            return;
          case "g":
            e.preventDefault();
            setGitOpen((v) => !v);
            setDrawerOpen(false);
            return;
          case "f":
            e.preventDefault();
            termActions.current?.refit();
            return;
          case "x":
            e.preventDefault();
            termActions.current?.reset();
            return;
        }
      }
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, []);

  const openQuickFile = async (path: string) => {
    setQuickOpen(false);
    const result = await loadPreview(path);
    if (result.ok) setQuickPreview(result.preview);
    else toast(result.message ?? t("couldNotReadFile"));
  };

  const deleting = useRef(new Set<string>());
  const handleDelete = async (id: string) => {
    if (deleting.current.has(id)) return;
    deleting.current.add(id);
    try {
      const result = await deleteSession({ identity: id, headers: buildCSRFHeaders() });
      if (result.success) {
        setSessions((list) => list.filter((s) => s.id !== id));
        if (activeId === id) setActiveId(null);
      } else {
        toast(result.errors[0]?.message ?? t("somethingWentWrong"));
      }
    } finally {
      deleting.current.delete(id);
    }
  };

  const settingsSession = ordered.find((s) => s.id === settingsFor) ?? null;
  const sessionToDelete = ordered.find((s) => s.id === deleteFor) ?? null;

  const hamburger = (
    <button
      id="nav-toggle-button"
      onClick={() => setNavOpen((v) => !v)}
      className="grid h-7 w-7 shrink-0 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:text-fg md:hidden"
      title="DALA"
    >
      <svg viewBox="0 0 16 16" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.5">
        <path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h11" strokeLinecap="round" />
      </svg>
    </button>
  );

  return (
    <div className="flex h-full w-full overflow-hidden bg-bg0 text-fg">
      {navOpen && (
        <div
          className="fixed inset-0 z-20 bg-black/50 md:hidden"
          onClick={() => setNavOpen(false)}
        />
      )}
      <div
        className={`fixed inset-y-0 left-0 z-30 transition-transform duration-200 md:static md:z-auto md:translate-x-0 ${
          navOpen ? "translate-x-0" : "-translate-x-full"
        }`}
      >
        <Sidebar
          sessions={ordered}
          activeId={active?.id ?? null}
          connected={connected}
          creating={creating}
          onSelect={(id) => {
            setActiveId(id);
            setNavOpen(false);
          }}
          onCreate={() => void handleCreate()}
          onOpenSettings={setSettingsFor}
          onDelete={setDeleteFor}
        />
      </div>

      <main className="flex min-w-0 flex-1 flex-col">
        {active ? (
          <>
            <header className="flex h-11 shrink-0 items-center gap-2 border-b border-line bg-bg1 px-3 sm:gap-3 sm:px-4">
              {hamburger}
              <span className="truncate font-mono text-sm text-fg">{active.name}</span>
              <span
                className="hidden truncate font-mono text-xs text-fg-muted sm:block"
                title={active.cwd}
              >
                {shortPath(active.cwd, 60)}
              </span>
              <div className="flex-1" />
              <span
                className={`hidden font-mono text-[11px] sm:block ${
                  active.status === "running" ? "text-mint" : "text-fg-muted"
                }`}
              >
                {active.status === "running"
                  ? t("running")
                  : active.exitCode != null
                    ? t("exitedWithCode", { code: active.exitCode })
                    : t("exited")}
              </span>
              <Tooltip
                label={t("quickOpenTitle")}
                description={t("quickOpenDesc")}
                keys={isMac ? "⌘P" : "Ctrl+P"}
              >
                <button
                  id="quick-open-button"
                  onClick={() => setQuickOpen(true)}
                  className="rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg"
                >
                  <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
                    <circle cx="7" cy="7" r="4" />
                    <path d="m13 13-3.2-3.2" strokeLinecap="round" />
                  </svg>
                </button>
              </Tooltip>
              <Tooltip label={t("filesTitle")} description={t("filesDesc")} keys={modShiftCombo("e")}>
                <button
                  id="toggle-drawer-button"
                  onClick={() => {
                    setDrawerOpen((v) => !v);
                    setGitOpen(false);
                  }}
                  className={`rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${
                    drawerOpen
                      ? "border-mint/50 text-mint"
                      : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
                  }`}
                >
                  {t("files")}
                </button>
              </Tooltip>
              <Tooltip label={t("gitTitle")} description={t("gitDesc")} keys={modShiftCombo("g")}>
                <button
                  id="toggle-git-button"
                  onClick={() => {
                    setGitOpen((v) => !v);
                    setDrawerOpen(false);
                  }}
                  className={`rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${
                    gitOpen
                      ? "border-mint/50 text-mint"
                      : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
                  }`}
                >
                  {t("git")}
                </button>
              </Tooltip>
              <Tooltip label={t("refitWidth")} description={t("refitDesc")} keys={modShiftCombo("f")}>
                <button
                  id="terminal-refit-button"
                  onClick={() => termActions.current?.refit()}
                  className="rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg"
                >
                  {t("refitWidth")}
                </button>
              </Tooltip>
              <Tooltip label={t("resetTerminal")} description={t("resetDesc")} keys={modShiftCombo("x")}>
                <button
                  id="terminal-reset-button"
                  onClick={() => termActions.current?.reset()}
                  className="rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg"
                >
                  {t("resetTerminal")}
                </button>
              </Tooltip>
              <Tooltip label={t("sessionSettings")} description={t("settingsDesc")}>
                <button
                  onClick={() => setSettingsFor(active.id)}
                  className="rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg"
                >
                  {t("settings")}
                </button>
              </Tooltip>
            </header>

            <div className="relative min-h-0 flex-1 bg-[#0b0c0e]">
              <TerminalView
                key={active.id}
                sessionId={active.id}
                actionsRef={termActions}
                onError={toast}
                onCwdChange={(cwd) => {
                  if (followCwd) setDrawerPath(cwd);
                }}
              />
              {active.status === "exited" && (
                <div className="absolute inset-0 z-10 grid place-items-center bg-bg0/70 backdrop-blur-[1px]">
                  <div className="flex flex-col items-center gap-3 rounded-xl border border-line bg-bg1 px-8 py-6 shadow-2xl">
                    <span className="font-mono text-[13px] text-fg-muted">
                      {active.exitCode != null
                        ? t("shellExitedWithCode", { code: active.exitCode })
                        : t("shellExited")}
                    </span>
                    <button
                      id="overlay-restart-button"
                      onClick={() => void handleRestart(active.id)}
                      className="rounded-md bg-mint px-4 py-1.5 text-[13px] font-medium text-black transition-colors hover:brightness-110"
                    >
                      {t("restartShell")}
                    </button>
                  </div>
                </div>
              )}
            </div>
          </>
        ) : (
          <div className="relative grid flex-1 place-items-center">
            <div className="absolute left-3 top-3">{hamburger}</div>
            <div className="flex flex-col items-center gap-4">
              <pre className="select-none font-mono text-xs leading-4 text-fg-muted/70">{`
 ██████   █████  ██      █████
 ██   ██ ██   ██ ██     ██   ██
 ██   ██ ███████ ██     ███████
 ██████  ██   ██ ██████ ██   ██`}</pre>
              <p className="text-[13px] text-fg-muted">{t("tagline")}</p>
              <button
                onClick={() => void handleCreate()}
                disabled={creating}
                className="rounded-md bg-mint px-4 py-1.5 text-[13px] font-medium text-black transition-colors hover:brightness-110 disabled:opacity-50"
              >
                {t("newTerminal")}
              </button>
            </div>
          </div>
        )}
      </main>

      {gitOpen && active && (
        <GitPanel path={active.cwd} onClose={() => setGitOpen(false)} onError={toast} />
      )}

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

      {quickOpen && active && (
        <QuickOpen
          root={active.cwd}
          onPick={(path) => void openQuickFile(path)}
          onClose={() => setQuickOpen(false)}
          onError={toast}
        />
      )}

      {quickPreview && (
        <FilePreview
          preview={quickPreview}
          onClose={() => setQuickPreview(null)}
          onError={toast}
          onSaved={(savedPath, savedContent, savedSize) => {
            setQuickPreview((current) =>
              current && "content" in current && current.path === savedPath
                ? { ...current, content: savedContent, size: savedSize }
                : current,
            );
          }}
        />
      )}

      {sessionToDelete && (
        <div
          className="fixed inset-0 z-40 grid place-items-center bg-black/60 p-4 sm:p-6"
          onClick={() => setDeleteFor(null)}
        >
          <div
            id="delete-session-modal"
            className="w-full max-w-sm rounded-xl border border-line bg-bg1 shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <header className="border-b border-line px-4 py-3">
              <span className="text-[15px] font-medium text-fg">{t("reallyDelete")}</span>
            </header>
            <div className="space-y-1 px-4 py-4">
              <div className="truncate font-mono text-sm text-fg">{sessionToDelete.name}</div>
              <div className="truncate font-mono text-xs text-fg-muted" title={sessionToDelete.cwd}>
                {sessionToDelete.cwd}
              </div>
            </div>
            <footer className="flex justify-end gap-2 border-t border-line px-4 py-3">
              <button
                id="cancel-delete-button"
                onClick={() => setDeleteFor(null)}
                className="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-[13px] text-fg-muted transition-colors hover:text-fg"
              >
                {t("cancel")} <Kbd>Esc</Kbd>
              </button>
              <button
                id="confirm-delete-button"
                autoFocus
                onKeyDown={(e) => {
                  if (e.key === "Escape") setDeleteFor(null);
                }}
                onClick={() => {
                  setDeleteFor(null);
                  void handleDelete(sessionToDelete.id);
                }}
                className="inline-flex items-center gap-1.5 rounded-md bg-danger/90 px-3 py-1.5 text-[13px] font-medium text-black transition-colors hover:bg-danger"
              >
                {t("deleteSession")} <Kbd>⏎</Kbd>
              </button>
            </footer>
          </div>
        </div>
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
        {toasts.map((item) => (
          <div
            key={item.id}
            className="pointer-events-auto max-w-xs rounded-lg border border-danger/40 bg-bg1 px-3 py-2 text-[13px] text-fg shadow-xl [overflow-wrap:anywhere]"
          >
            {item.message}
          </div>
        ))}
      </div>
    </div>
  );
}
