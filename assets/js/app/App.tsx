import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Channel } from "phoenix";
import {
  buildCSRFHeaders,
  createSession,
  deleteSession,
  kickViewers,
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
import QuickShellPanel from "./QuickShellPanel";
import FileDrawer from "./FileDrawer";
import GitPanel from "./GitPanel";
import SettingsModal from "./SettingsModal";
import QuickOpen from "./QuickOpen";
import FilePreview, { type Preview } from "./FilePreview";
import { loadPreview } from "./loadPreview";
import { isMac, Kbd, modShiftCombo, Tooltip } from "./shortcuts";
import { historyLines, shortPath } from "./util";
import { useI18n } from "./i18n";

const SESSION_FIELDS = [
  "id",
  "name",
  "shell",
  "cwd",
  "status",
  "exitCode",
  "scrollbackLimit",
  "ephemeral",
  "insertedAt",
] as const;

type Toast = { id: number; message: string };

const clampWidth = (value: number, min: number, max: number) =>
  Math.min(Math.max(Math.round(value), min), Math.max(min, max));

/** Default panel widths in px (352 = the former w-[22rem]). */
const PANEL_W = { sidebar: 256, qs: 800, drawer: 352, git: 352 };

export default function App() {
  const { t } = useI18n();
  const [sessions, setSessions] = useState<Session[]>([]);
  const [activeId, setActiveId] = useState<string | null>(
    () => localStorage.getItem("dala:active") || null,
  );
  const [connected, setConnected] = useState(false);
  const [creating, setCreating] = useState(false);
  const [navOpen, setNavOpen] = useState(false);
  // Desktop sidebar collapse (VS Code's Ctrl/Cmd+B), remembered per browser.
  const [sidebarHidden, setSidebarHidden] = useState(
    () => localStorage.getItem("dala:sidebar-hidden") === "1",
  );
  const toggleSidebar = () =>
    setSidebarHidden((v) => {
      localStorage.setItem("dala:sidebar-hidden", v ? "0" : "1");
      return !v;
    });
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
  const termActions = useRef<{ reset: () => void; refit: () => void; focus: () => void } | null>(null);

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

  // Trail of visited sessions plus quick-shell panel state. Refs, because
  // the channel handlers below are registered once and must not see stale
  // state.
  const activeIdRef = useRef<string | null>(null);
  const historyRef = useRef<string[]>([]);
  const sessionsRef = useRef<Session[]>([]);
  useEffect(() => {
    sessionsRef.current = sessions;
  }, [sessions]);

  // The quick shells live in one overlay panel (not the sidebar): ephemeral
  // sessions as tabs, toggled open/closed, maximizable.
  const [qsIds, setQsIds] = useState<string[]>([]);
  const [qsActiveId, setQsActiveId] = useState<string | null>(null);
  const [qsOpen, setQsOpen] = useState(false);
  const [qsMax, setQsMax] = useState(false);
  const qsActions = useRef<{ reset: () => void; refit: () => void; focus: () => void } | null>(
    null,
  );
  const qsRef = useRef({ ids: [] as string[], activeId: null as string | null, open: false });
  qsRef.current = { ids: qsIds, activeId: qsActiveId, open: qsOpen };

  const focusQuickShell = () => window.setTimeout(() => qsActions.current?.focus(), 150);

  // Quick shells are disposable — any ephemeral session surviving a reload
  // is a leftover, so clean it up once the first session list arrives.
  const qsCleanedRef = useRef(false);
  useEffect(() => {
    if (qsCleanedRef.current || sessions.length === 0) return;
    qsCleanedRef.current = true;
    for (const orphan of sessions.filter((s) => s.ephemeral)) {
      void deleteSession({ identity: orphan.id, headers: buildCSRFHeaders() });
    }
  }, [sessions]);

  // Draggable panel widths, remembered per browser. Double-clicking a
  // handle resets that panel; settings has a reset-all button (it fires
  // the dala:reset-layout event).
  const [sidebarW, setSidebarW] = useState(() =>
    clampWidth(Number(localStorage.getItem("dala:sidebar-w")) || PANEL_W.sidebar, 180, 440),
  );
  const [qsW, setQsW] = useState(() =>
    clampWidth(
      Number(localStorage.getItem("dala:qs-w")) || PANEL_W.qs,
      380,
      window.innerWidth - 160,
    ),
  );
  const [drawerW, setDrawerW] = useState(() =>
    clampWidth(Number(localStorage.getItem("dala:drawer-w")) || PANEL_W.drawer, 260, 720),
  );
  const [gitW, setGitW] = useState(() =>
    clampWidth(Number(localStorage.getItem("dala:git-w")) || PANEL_W.git, 280, 800),
  );
  useEffect(() => localStorage.setItem("dala:sidebar-w", String(sidebarW)), [sidebarW]);
  useEffect(() => localStorage.setItem("dala:qs-w", String(qsW)), [qsW]);
  useEffect(() => localStorage.setItem("dala:drawer-w", String(drawerW)), [drawerW]);
  useEffect(() => localStorage.setItem("dala:git-w", String(gitW)), [gitW]);
  useEffect(() => {
    const reset = () => {
      setSidebarW(PANEL_W.sidebar);
      setQsW(PANEL_W.qs);
      setDrawerW(PANEL_W.drawer);
      setGitW(PANEL_W.git);
    };
    window.addEventListener("dala:reset-layout", reset);
    return () => window.removeEventListener("dala:reset-layout", reset);
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
      session_deleted: ({ id }) => {
        setSessions((list) => list.filter((s) => s.id !== id));
        // A quick shell destroyed itself (exit/Ctrl+D): drop its tab, and
        // the whole panel when it was the last one.
        if (qsRef.current.ids.includes(id)) {
          const rest = qsRef.current.ids.filter((x) => x !== id);
          setQsIds(rest);
          if (rest.length === 0) {
            setQsOpen(false);
            setQsMax(false);
            setQsActiveId(null);
            termActions.current?.focus();
          } else if (qsRef.current.activeId === id) {
            setQsActiveId(rest[rest.length - 1]);
            if (qsRef.current.open) focusQuickShell();
          }
        }
        // The active session was deleted: return to the most recently
        // visited one that still exists.
        if (id === activeIdRef.current) {
          const previous = [...historyRef.current]
            .reverse()
            .find((h) => h !== id && sessionsRef.current.some((s) => s.id === h));
          if (previous) setActiveId(previous);
        }
      },
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

  // Quick shells (ephemeral) live in their overlay panel, not the sidebar
  // or the active-session rotation.
  const ordered = useMemo(
    () =>
      [...sessions]
        .filter((s) => !s.ephemeral)
        .sort((a, b) => a.insertedAt.localeCompare(b.insertedAt)),
    [sessions],
  );
  const active = ordered.find((s) => s.id === activeId) ?? ordered[0] ?? null;
  const qsSessions = qsIds
    .map((id) => sessions.find((s) => s.id === id))
    .filter((s): s is Session => Boolean(s));
  const qsSession = qsSessions.find((s) => s.id === qsActiveId) ?? qsSessions[0] ?? null;

  useEffect(() => {
    if (!active) return;
    localStorage.setItem("dala:active", active.id);
    activeIdRef.current = active.id;
    const trail = historyRef.current.filter((id) => id !== active.id);
    trail.push(active.id);
    historyRef.current = trail.slice(-20);
  }, [active?.id]);

  // Keep the drawer on the terminal's cwd while following.
  useEffect(() => {
    if (followCwd && active) setDrawerPath(active.cwd);
  }, [followCwd, active?.id, active?.cwd]);

  const handleCreate = async (input: { cwd?: string; ephemeral?: boolean } = {}) => {
    setCreating(true);
    const result = await createSession({
      input,
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

  // Quick shells (Ctrl+Shift+` or the header button): ephemeral terminals
  // in an overlay panel, opened in the active session's directory — for
  // vim/git while the main shell is busy. The toggle hides the panel but
  // keeps the shells; `exit`/Ctrl+D inside one destroys that session, which
  // drops its tab via the session_deleted broadcast.
  const createQuickShell = async (cwd?: string) => {
    const result = await createSession({
      input: { cwd: cwd || undefined, ephemeral: true },
      fields: [...SESSION_FIELDS],
      headers: buildCSRFHeaders(),
    });
    if (!result.success) {
      toast(result.errors[0]?.message ?? t("couldNotCreateTerminal"));
      return;
    }
    const session = result.data as unknown as Session;
    upsertSession(session);
    setQsIds((ids) => (ids.includes(session.id) ? ids : [...ids, session.id]));
    setQsActiveId(session.id);
    setQsOpen(true);
    focusQuickShell();
  };

  // Closing the panel (Esc, ✕, or the toggle) destroys every quick shell:
  // they are scratch paper, not workspaces — reopening starts fresh.
  const closeQuickShell = () => {
    const ids = qsRef.current.ids;
    setQsIds([]);
    setQsActiveId(null);
    setQsOpen(false);
    setQsMax(false);
    setSessions((list) => list.filter((s) => !ids.includes(s.id)));
    termActions.current?.focus();
    for (const id of ids) {
      void deleteSession({ identity: id, headers: buildCSRFHeaders() });
    }
  };

  const toggleQuickShell = async () => {
    if (qsRef.current.open) closeQuickShell();
    else await createQuickShell(active?.cwd);
  };
  const quickShellRef = useRef(() => {});
  quickShellRef.current = () => void toggleQuickShell();

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

  // Kick other zellij/tmux viewers capping this terminal's size, then
  // reassert our own size.
  const kickOtherViewers = async () => {
    if (!active) return;
    const result = await kickViewers({
      input: { id: active.id },
      fields: ["multiplexer", "session", "kicked", "error"],
      headers: buildCSRFHeaders(),
    });
    if (result.success) {
      const data = result.data as unknown as {
        multiplexer: string;
        kicked: number;
        error: string | null;
      };
      if (data.error) {
        toast(data.error);
      } else {
        toast(t("kickedViewers", { count: data.kicked, mux: data.multiplexer }));
        termActions.current?.refit();
      }
    } else {
      toast(result.errors[0]?.message ?? t("somethingWentWrong"));
    }
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

      // VS Code pair — Ctrl+` jumps focus back into the terminal (the quick
      // shell's, when its panel is open); Ctrl+Shift+` toggles the quick
      // shell overlay. macOS eats Cmd+` (window cycling), so it is the
      // Control key there as well, exactly like VS Code.
      if (e.code === "Backquote") {
        e.preventDefault();
        if (e.shiftKey) quickShellRef.current();
        else (qsRef.current.open ? qsActions : termActions).current?.focus();
        return;
      }

      // Ctrl/Cmd+B toggles the sidebar; plain Ctrl+B inside the terminal
      // stays with readline (backward-char), mirroring the Ctrl+P rule.
      if (!e.shiftKey && key === "b") {
        const inTerminal = (e.target as HTMLElement | null)?.closest?.(".xterm");
        if (inTerminal && !e.metaKey) return;
        e.preventDefault();
        toggleSidebar();
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
    <Tooltip label={t("toggleSidebar")} keys={isMac ? "⌘B" : "Ctrl+B"}>
      <button
        id="nav-toggle-button"
        onClick={() => {
          if (window.matchMedia("(min-width: 768px)").matches) toggleSidebar();
          else setNavOpen((v) => !v);
        }}
        className="grid h-7 w-7 shrink-0 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:text-fg"
      >
        <svg viewBox="0 0 16 16" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.5">
          <path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h11" strokeLinecap="round" />
        </svg>
      </button>
    </Tooltip>
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
        className={`fixed inset-y-0 left-0 z-30 transition-transform duration-200 ${
          navOpen ? "translate-x-0" : "-translate-x-full"
        } ${sidebarHidden ? "md:hidden" : "md:static md:z-auto md:translate-x-0"}`}
      >
        <Sidebar
          sessions={ordered}
          activeId={active?.id ?? null}
          connected={connected}
          creating={creating}
          width={sidebarW}
          onResize={(x) => setSidebarW(clampWidth(x, 180, 440))}
          onResetWidth={() => setSidebarW(PANEL_W.sidebar)}
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
              <Tooltip
                label={t("quickShellTitle")}
                description={t("quickShellDesc")}
                keys="Ctrl+Shift+`"
              >
                <button
                  id="quick-shell-button"
                  onClick={() => quickShellRef.current()}
                  className={`shrink-0 rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${
                    qsOpen
                      ? "border-mint/50 text-mint"
                      : "border-line text-fg-muted hover:border-mint/60 hover:text-mint"
                  }`}
                >
                  ⚡&gt;_
                </button>
              </Tooltip>
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
              <Tooltip label={t("kickViewers")} description={t("kickViewersHint")}>
                <button
                  id="kick-viewers-header-button"
                  onClick={() => void kickOtherViewers()}
                  className="rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg"
                >
                  {t("kickViewersAction")}
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
                  id="session-settings-button"
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
                scrollbackLines={historyLines(active.scrollbackLimit)}
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
        <GitPanel
          path={active.cwd}
          onClose={() => setGitOpen(false)}
          onError={toast}
          width={gitW}
          onResize={(x) => setGitW(clampWidth(window.innerWidth - x, 280, 800))}
          onResetWidth={() => setGitW(PANEL_W.git)}
        />
      )}

      {qsOpen && qsSession && (
        <QuickShellPanel
          sessions={qsSessions}
          active={qsSession}
          onSelect={(id) => {
            setQsActiveId(id);
            focusQuickShell();
          }}
          onAdd={() => void createQuickShell(qsSession.cwd || active?.cwd)}
          maximized={qsMax}
          onToggleMax={() => setQsMax((v) => !v)}
          onClose={closeQuickShell}
          width={qsW}
          onResize={(x) => setQsW(clampWidth(window.innerWidth - x, 380, window.innerWidth - 160))}
          onResetWidth={() => setQsW(PANEL_W.qs)}
          actionsRef={qsActions}
          onError={toast}
        />
      )}

      {drawerOpen && active && (
        <FileDrawer
          path={drawerPath ?? active.cwd}
          width={drawerW}
          onResize={(x) => setDrawerW(clampWidth(window.innerWidth - x, 260, 720))}
          onResetWidth={() => setDrawerW(PANEL_W.drawer)}
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
