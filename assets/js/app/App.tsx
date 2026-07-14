import React, { useCallback, useEffect, useRef, useState } from "react";
import { createSession, deleteSession, foregroundApp, kickViewers } from "../ash_rpc";
import { getDeviceId } from "./deviceId";
import { call } from "./rpc";
import type { AgentEventPayload } from "../ash_types";
import Sidebar, { Session } from "./Sidebar";
import TerminalView, { type TerminalActions } from "./TerminalView";
import TouchKeyBar, { useCoarsePointer } from "./TouchKeyBar";
import { applyCtrl, nextLatch, sequenceFor, type BarKey } from "./touchKeys";
import QuickShellPanel from "./QuickShellPanel";
import InputBar, { AGENT_LABELS } from "./InputBar";
import FileDrawer from "./FileDrawer";
import GitPanel from "./GitPanel";
import SettingsModal from "./SettingsModal";
import QuickOpen from "./QuickOpen";
import FilePreview, { type Preview } from "./FilePreview";
import { loadPreview } from "./loadPreview";
import { isMac, Kbd, modShiftCombo, Tooltip } from "./shortcuts";
import { useSessions, SESSION_FIELDS } from "./hooks/useSessions";
import { usePanelLayout, clampWidth, PANEL_W } from "./hooks/usePanelLayout";
import { useGlobalShortcuts } from "./hooks/useGlobalShortcuts";
import { useNotifications, agentStateFor } from "./hooks/useNotifications";
import { historyLines, shortPath } from "./util";
import { useI18n } from "./i18n";

type Toast = { id: number; message: string };

// Touch density (Apple HIG ≈44px targets): coarse-pointer devices get
// taller, roomier toolbar buttons with ≥14px text. Gated entirely on
// `pointer-coarse:` so desktop stays pixel-identical.
const touchToolbarBtn = "pointer-coarse:min-h-10 pointer-coarse:px-3 pointer-coarse:text-sm";

export default function App() {
  const { t } = useI18n();
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
  // Composer is per-session: each session keeps its own open flag, draft
  // and detected foreground agent — switching sessions never mixes them.
  const [composerOpen, setComposerOpen] = useState<Record<string, boolean>>({});
  const [composerApps, setComposerApps] = useState<Record<string, string | null>>({});
  const [composerDrafts, setComposerDrafts] = useState<Record<string, string>>({});
  const [composerFocusNonce, setComposerFocusNonce] = useState(0);
  const composerFocusConsumedRef = useRef(0);
  // Agent activity per session (from OSC 777 plugin events): drives the
  // sidebar dots, notifications and the composer auto-toggle.
  const [agentStatus, setAgentStatus] = useState<
    Record<string, { state: "working" | "attention" | "done"; at: number }>
  >({});
  const [quickPreview, setQuickPreview] = useState<Preview | null>(null);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastSeq = useRef(0);
  const termActions = useRef<TerminalActions | null>(null);

  // Touch UI: phones get an overflow toolbar menu, a terminal key bar and a
  // tappable composer hint instead of shortcut chips.
  const coarsePointer = useCoarsePointer();
  const [toolbarMenuOpen, setToolbarMenuOpen] = useState(false);
  // Sticky Ctrl from the touch key bar: latched until the next key — a bar
  // key or a single soft-keyboard character — goes out with Ctrl applied.
  const [ctrlLatch, setCtrlLatch] = useState(false);
  const ctrlLatchRef = useRef(false);
  ctrlLatchRef.current = ctrlLatch;
  const termInputHookRef = useRef<((data: string) => string) | null>(null);
  termInputHookRef.current = (data) => {
    if (!ctrlLatchRef.current) return data;
    const wrapped = applyCtrl(data);
    if (wrapped == null) return data;
    setCtrlLatch(false);
    return wrapped;
  };
  const sendBarKey = (key: BarKey) => {
    termActions.current?.sendKey(sequenceFor(key, ctrlLatchRef.current));
    setCtrlLatch(nextLatch(key, ctrlLatchRef.current));
  };

  const toast = useCallback((message: string) => {
    const id = ++toastSeq.current;
    setToasts((list) => [...list, { id, message }]);
    window.setTimeout(() => setToasts((list) => list.filter((x) => x.id !== id)), 5000);
  }, []);

  // The quick shells live in one overlay panel (not the sidebar): ephemeral
  // sessions as tabs, toggled open/closed, maximizable.
  const [qsIds, setQsIds] = useState<string[]>([]);
  const [qsActiveId, setQsActiveId] = useState<string | null>(null);
  const [qsOpen, setQsOpen] = useState(false);
  const [qsMax, setQsMax] = useState(false);
  const qsActions = useRef<TerminalActions | null>(null);
  const qsRef = useRef({ ids: [] as string[], activeId: null as string | null, open: false });
  qsRef.current = { ids: qsIds, activeId: qsActiveId, open: qsOpen };

  const focusQuickShell = () => window.setTimeout(() => qsActions.current?.focus(), 150);

  const agentEventRef = useRef<(p: AgentEventPayload) => void>(() => {});

  const {
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
    handleCreate: createMainSession,
    handleRestart: restartMainSession,
    handleDelete,
    handleReorder,
  } = useSessions({
    toast,
    onAgentEvent: (payload) => agentEventRef.current(payload),
    onSessionDeleted: (id) => {
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
    },
  });

  const { sidebarW, setSidebarW, qsW, setQsW, drawerW, setDrawerW, gitW, setGitW } =
    usePanelLayout();

  const { notifyAgentEvent } = useNotifications({
    activeIdRef,
    sessionsRef,
    toast,
    onJump: setActiveId,
  });

  const qsSessions = qsIds
    .map((id) => sessions.find((s) => s.id === id))
    .filter((s): s is Session => Boolean(s));
  const qsSession = qsSessions.find((s) => s.id === qsActiveId) ?? qsSessions[0] ?? null;

  // Switching sessions: an open composer is where typing continues — put the
  // focus there (cursor at the end), not in the shell the terminal grabs on
  // mount. Runs after TerminalView's own mount focus, so it wins.
  useEffect(() => {
    if (active && composerOpen[active.id]) {
      setComposerFocusNonce((n) => n + 1);
    }
    // A latched Ctrl aims at THIS session's terminal — never carry it over.
    setCtrlLatch(false);
    setToolbarMenuOpen(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active?.id]);

  // Composer open/close changes the terminal's height — refit right away
  // (and once more after the layout settles) so TUIs never sit clipped.
  const activeComposerOpen = active ? Boolean(composerOpen[active.id]) : false;
  useEffect(() => {
    const t1 = window.setTimeout(() => termActions.current?.refit(), 50);
    const t2 = window.setTimeout(() => termActions.current?.refit(), 300);
    return () => {
      window.clearTimeout(t1);
      window.clearTimeout(t2);
    };
  }, [activeComposerOpen]);

  // Keep the drawer on the terminal's cwd while following.
  useEffect(() => {
    if (followCwd && active) setDrawerPath(active.cwd);
  }, [followCwd, active?.id, active?.cwd]);

  const handleCreate = async (input: { cwd?: string; ephemeral?: boolean } = {}) => {
    const session = await createMainSession(input);
    if (session) setNavOpen(false);
  };

  // Quick shells (Ctrl+Shift+` or the header button): ephemeral terminals
  // in an overlay panel, opened in the active session's directory — for
  // vim/git while the main shell is busy. The toggle hides the panel but
  // keeps the shells; `exit`/Ctrl+D inside one destroys that session, which
  // drops its tab via the session_deleted broadcast.
  const createQuickShell = async (cwd?: string) => {
    // Quick shells are stamped to this device too: they open right here,
    // so no other device should ever win their first-attach adoption.
    const result = await call<Session>(createSession, {
      input: { cwd: cwd || undefined, ephemeral: true, deviceId: getDeviceId() },
      fields: [...SESSION_FIELDS],
    });
    if (!result.ok) {
      toast(result.error || t("couldNotCreateTerminal"));
      return;
    }
    const session = result.data;
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
      void call<unknown>(deleteSession, { identity: id });
    }
  };

  const toggleQuickShell = async () => {
    if (qsRef.current.open) closeQuickShell();
    else await createQuickShell(active?.cwd);
  };
  const toggleComposerRef = useRef(() => {});
  const quickShellRef = useRef(() => {});
  quickShellRef.current = () => void toggleQuickShell();

  const handleRestart = async (id: string) => {
    const ok = await restartMainSession(id);
    if (!ok) return;
    // The revived shell is a fresh PTY at the default size — push our real size
    // immediately instead of waiting for a resize event.
    termActions.current?.refit();
    window.setTimeout(() => termActions.current?.refit(), 200);
  };

  agentEventRef.current = (p) => {
    const state = agentStateFor(p.event);
    if (!state) return;
    setAgentStatus((m) => ({ ...m, [p.id]: { state, at: Date.now() } }));

    // Warp's auto-toggle state machine, per session (background sessions
    // included — their composer is ready when you switch back): approvals and
    // questions want raw terminal keys → close; working/done → open, without
    // stealing focus. idle_prompt is "waiting for your input" — exactly when
    // the composer is useful, so it never closes it.
    if (["permission_request", "question_asked"].includes(p.event)) {
      setComposerOpen((m) => ({ ...m, [p.id]: false }));
      // The approval/choice wants raw terminal keys — hand focus back right
      // away (only for the session on screen; background sessions get the
      // notification instead).
      if (p.id === activeIdRef.current) {
        window.setTimeout(() => termActions.current?.focus(), 100);
      }
    } else if (state !== "attention") {
      if (p.agent in AGENT_LABELS) {
        setComposerApps((apps) => ({ ...apps, [p.id]: p.agent }));
      }
      setComposerOpen((m) => ({ ...m, [p.id]: true }));
    }

    notifyAgentEvent(p);
  };

  // The shortcut is a three-state cycle: closed → open+focus; open but
  // unfocused (e.g. after an auto-open) → just focus, cursor at the end;
  // open and focused → close back to the terminal.
  const toggleComposer = () => {
    const id = activeIdRef.current;
    if (!id) return;
    const editorFocused = Boolean(document.activeElement?.closest?.("#composer-editor"));
    setComposerOpen((m) => {
      const open = !!m[id];
      if (open && !editorFocused) {
        setComposerFocusNonce((n) => n + 1);
        return m;
      }
      if (!open) {
        // The touch key bar disappears behind the composer — a Ctrl latched
        // there must not silently rewrite the next composer keystroke's
        // terminal delivery once the composer closes again.
        setCtrlLatch(false);
        setComposerFocusNonce((n) => n + 1);
        void call<{ app: string }>(foregroundApp, {
          input: { id },
          fields: ["app", "cmdline"],
        }).then((result) => {
          if (result.ok) {
            const app = result.data.app;
            setComposerApps((apps) => ({
              ...apps,
              [id]: app === "shell" || app === "unknown" ? null : app,
            }));
          }
        });
      } else {
        termActions.current?.focus();
      }
      return { ...m, [id]: !open };
    });
  };
  toggleComposerRef.current = toggleComposer;

  // Voice shortcut: make sure the composer is open, then hand off to the
  // input bar (start recording / stop+transcribe on the second press).
  const voiceShortcutRef = useRef<() => void>(() => {});
  voiceShortcutRef.current = () => {
    const id = activeIdRef.current;
    if (!id) return;
    let delay = 0;
    setComposerOpen((m) => {
      if (!m[id]) {
        delay = 200;
        return { ...m, [id]: true };
      }
      return m;
    });
    window.setTimeout(() => window.dispatchEvent(new CustomEvent("dala:voice")), delay);
  };

  // Deliver input-bar text with the right per-agent strategy (ported from
  // Warp): ask the server what runs in the session's foreground first.
  const sendToForegroundApp = async (text: string, submit: boolean) => {
    if (!active) return;
    let app = "unknown";
    const appResult = await call<{ app: string }>(foregroundApp, {
      input: { id: active.id },
      fields: ["app", "cmdline"],
    });
    if (appResult.ok) app = appResult.data.app;
    const strategy =
      app === "codex"
        ? ("bracketed" as const)
        : app === "copilot"
          ? ("bracketed-delayed" as const)
          : app === "claude" || app === "opencode" || app === "gemini"
            ? // Warp sends bare text to these, but a bare multiline paste
              // would submit at the first newline — bracket those.
              text.includes("\n")
              ? ("bracketed-delayed" as const)
              : ("delayed" as const)
            : undefined;

    // Agents only attachment-ify a pasted path when the paste IS the path:
    // opencode turns it into a File chip, Claude Code into [Image #N] — mixed
    // into a sentence it degrades to plain text (and non-vision models can't
    // follow it). So attachment paths each go out as their own bracketed
    // paste first, then the remaining message, then the submit.
    const isAgent = ["claude", "opencode", "gemini", "codex", "copilot"].includes(app);
    const pathPattern = /\S*dala-paste\/paste-[^\s]+/g;
    const paths = isAgent ? (text.match(pathPattern) ?? []) : [];
    if (paths.length > 0) {
      const rest = text.replace(pathPattern, "").replace(/[ \t]{2,}/g, " ").trim();
      const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
      const image = /\.(png|jpe?g|gif|webp|bmp|svg|tiff?)$/i;
      for (const path of paths) {
        // Text files: Claude Code and Gemini attach @path references inline
        // (content lands in context, no Read round-trip, no permission
        // prompt); opencode/codex read bare paths. Images keep bare paths —
        // that's what all the image-attachment detectors key on.
        const prefix =
          !image.test(path) && (app === "claude" || app === "gemini") ? "@" : "";
        termActions.current?.sendText(prefix + path + " ", false, "bracketed");
        await wait(200);
      }
      if (rest) {
        termActions.current?.sendText(rest, false, rest.includes("\n") ? "bracketed" : undefined);
        await wait(120);
      }
      if (submit) termActions.current?.sendText("", true, strategy ?? "delayed");
      return;
    }

    termActions.current?.sendText(text, submit, strategy);
  };

  // Kick other zellij/tmux viewers capping this terminal's size, then
  // reassert our own size.
  const kickOtherViewers = async () => {
    if (!active) return;
    const result = await call<{
      multiplexer: string;
      kicked: number;
      error: string | null;
    }>(kickViewers, {
      input: { id: active.id },
      fields: ["multiplexer", "session", "kicked", "error"],
    });
    if (result.ok) {
      const data = result.data;
      if (data.error) {
        toast(data.error);
      } else {
        toast(t("kickedViewers", { count: data.kicked, mux: data.multiplexer }));
        termActions.current?.refit();
      }
    } else {
      toast(result.error || t("somethingWentWrong"));
    }
  };

  const toggleDrawer = () => {
    setDrawerOpen((v) => !v);
    setGitOpen(false);
  };
  const toggleGit = () => {
    setGitOpen((v) => !v);
    setDrawerOpen(false);
  };

  useGlobalShortcuts({
    termActions,
    qsActions,
    qsRef,
    quickShellRef,
    toggleComposerRef,
    voiceShortcutRef,
    toggleSidebar,
    openQuickOpen: () => setQuickOpen(true),
    toggleDrawer,
    toggleGit,
    onNotifyClick: (id) => {
      if (sessionsRef.current.some((s) => s.id === id)) setActiveId(id);
    },
  });

  const openQuickFile = async (path: string) => {
    setQuickOpen(false);
    const result = await loadPreview(path);
    if (result.ok) setQuickPreview(result.preview);
    else toast(result.message ?? t("couldNotReadFile"));
  };

  const settingsSession = ordered.find((s) => s.id === settingsFor) ?? null;
  const sessionToDelete = ordered.find((s) => s.id === deleteFor) ?? null;

  // One row of the narrow-screen toolbar overflow menu.
  const overflowItem = (id: string, label: string, run: () => void) => (
    <button
      id={id}
      onClick={() => {
        setToolbarMenuOpen(false);
        run();
      }}
      className="px-3 py-2 text-left font-mono text-[12px] text-fg-muted transition-colors hover:bg-bg2 hover:text-fg pointer-coarse:min-h-11 pointer-coarse:py-3 pointer-coarse:text-sm"
    >
      {label}
    </button>
  );

  const hamburger = (
    <Tooltip label={t("toggleSidebar")} keys={isMac ? "⌘B" : "Ctrl+B"}>
      <button
        id="nav-toggle-button"
        onClick={() => {
          if (window.matchMedia("(min-width: 768px)").matches) toggleSidebar();
          else setNavOpen((v) => !v);
        }}
        className="grid h-7 w-7 shrink-0 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:text-fg pointer-coarse:h-10 pointer-coarse:w-10"
      >
        <svg viewBox="0 0 16 16" className="h-4 w-4 pointer-coarse:h-5 pointer-coarse:w-5" fill="none" stroke="currentColor" strokeWidth="1.5">
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
          agentStatus={agentStatus}
          width={sidebarW}
          onResize={(x) => setSidebarW(clampWidth(x, 180, 440))}
          onResetWidth={() => setSidebarW(PANEL_W.sidebar)}
          onSelect={(id) => {
            setActiveId(id);
            setNavOpen(false);
            setAgentStatus((m) =>
              m[id] && m[id].state !== "working"
                ? Object.fromEntries(Object.entries(m).filter(([k]) => k !== id))
                : m,
            );
          }}
          onCreate={() => void handleCreate()}
          onOpenSettings={setSettingsFor}
          onDelete={setDeleteFor}
          onReorder={(id, beforeId) => void handleReorder(id, beforeId)}
        />
      </div>

      <main className="flex min-w-0 flex-1 flex-col pb-[env(safe-area-inset-bottom)]">
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
                className="max-sm:hidden"
              >
                <button
                  id="quick-shell-button"
                  onClick={() => quickShellRef.current()}
                  className={`shrink-0 rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${touchToolbarBtn} ${
                    qsOpen
                      ? "border-mint/50 text-mint"
                      : "border-line text-fg-muted hover:border-mint/60 hover:text-mint"
                  }`}
                >
                  ⚡&gt;_
                </button>
              </Tooltip>
              <Tooltip
                label={t("inputBarTitle")}
                description={t("inputBarHint")}
                keys={modShiftCombo("k")}
              >
                <button
                  id="input-bar-button"
                  onClick={() => toggleComposer()}
                  className={`shrink-0 rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${touchToolbarBtn} ${
                    composerOpen[active.id]
                      ? "border-mint/50 text-mint"
                      : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
                  }`}
                >
                  <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 pointer-coarse:h-4.5 pointer-coarse:w-4.5" fill="none" stroke="currentColor" strokeWidth="1.5">
                    <rect x="1.5" y="4" width="13" height="8" rx="1.5" />
                    <path d="M4 9.5h8" strokeLinecap="round" />
                  </svg>
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
                className="max-sm:hidden"
              >
                <button
                  id="quick-open-button"
                  onClick={() => setQuickOpen(true)}
                  className={`rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg ${touchToolbarBtn}`}
                >
                  <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 pointer-coarse:h-4.5 pointer-coarse:w-4.5" fill="none" stroke="currentColor" strokeWidth="1.5">
                    <circle cx="7" cy="7" r="4" />
                    <path d="m13 13-3.2-3.2" strokeLinecap="round" />
                  </svg>
                </button>
              </Tooltip>
              <Tooltip label={t("filesTitle")} description={t("filesDesc")} keys={modShiftCombo("e")}>
                <button
                  id="toggle-drawer-button"
                  onClick={toggleDrawer}
                  className={`rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${touchToolbarBtn} ${
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
                  onClick={toggleGit}
                  className={`rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${touchToolbarBtn} ${
                    gitOpen
                      ? "border-mint/50 text-mint"
                      : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
                  }`}
                >
                  {t("git")}
                </button>
              </Tooltip>
              <Tooltip
                label={t("kickViewers")}
                description={t("kickViewersHint")}
                className="max-sm:hidden"
              >
                <button
                  id="kick-viewers-header-button"
                  onClick={() => void kickOtherViewers()}
                  className={`rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg ${touchToolbarBtn}`}
                >
                  {t("kickViewersAction")}
                </button>
              </Tooltip>
              <Tooltip
                label={t("refitWidth")}
                description={t("refitDesc")}
                keys={modShiftCombo("f")}
                className="max-sm:hidden"
              >
                <button
                  id="terminal-refit-button"
                  onClick={() => termActions.current?.refit(true)}
                  className={`rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg ${touchToolbarBtn}`}
                >
                  {t("refitWidth")}
                </button>
              </Tooltip>
              <Tooltip
                label={t("resetTerminal")}
                description={t("resetDesc")}
                keys={modShiftCombo("x")}
                className="max-sm:hidden"
              >
                <button
                  id="terminal-reset-button"
                  onClick={() => termActions.current?.reset()}
                  className={`rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg ${touchToolbarBtn}`}
                >
                  {t("resetTerminal")}
                </button>
              </Tooltip>
              <Tooltip
                label={t("sessionSettings")}
                description={t("settingsDesc")}
                className="max-sm:hidden"
              >
                <button
                  id="session-settings-button"
                  onClick={() => setSettingsFor(active.id)}
                  className={`rounded-md border border-line px-2 py-1 font-mono text-[11px] text-fg-muted transition-colors hover:border-fg-muted hover:text-fg ${touchToolbarBtn}`}
                >
                  {t("settings")}
                </button>
              </Tooltip>
              {/* Narrow screens: everything above that is hidden lives in
                  this overflow menu — the toolbar itself never scrolls. */}
              <div className="relative sm:hidden">
                <button
                  id="toolbar-overflow-button"
                  aria-label={t("moreActions")}
                  onClick={() => setToolbarMenuOpen((v) => !v)}
                  className={`rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${touchToolbarBtn} ${
                    toolbarMenuOpen
                      ? "border-mint/50 text-mint"
                      : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
                  }`}
                >
                  ⋯
                </button>
                {toolbarMenuOpen && (
                  <>
                    <div
                      className="fixed inset-0 z-30"
                      onClick={() => setToolbarMenuOpen(false)}
                    />
                    <div
                      id="toolbar-overflow"
                      className="absolute right-0 top-full z-40 mt-1.5 flex w-52 flex-col rounded-lg border border-line bg-bg1 py-1 shadow-2xl shadow-black/50"
                    >
                      {overflowItem("overflow-quick-shell", t("quickShellTitle"), () =>
                        quickShellRef.current(),
                      )}
                      {overflowItem("overflow-quick-open", t("quickOpenTitle"), () =>
                        setQuickOpen(true),
                      )}
                      {overflowItem("overflow-kick-viewers", t("kickViewers"), () =>
                        void kickOtherViewers(),
                      )}
                      {overflowItem("overflow-refit", t("refitWidth"), () =>
                        termActions.current?.refit(true),
                      )}
                      {overflowItem("overflow-reset", t("resetTerminal"), () =>
                        termActions.current?.reset(),
                      )}
                      {overflowItem("overflow-settings", t("sessionSettings"), () =>
                        setSettingsFor(active.id),
                      )}
                    </div>
                  </>
                )}
              </div>
            </header>

            <div className="relative min-h-0 flex-1 overflow-hidden bg-[#0b0c0e]">
              <TerminalView
                key={active.id}
                sessionId={active.id}
                scrollbackLines={historyLines(active.scrollbackLimit)}
                actionsRef={termActions}
                inputHookRef={termInputHookRef}
                debugHandle
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

            {coarsePointer && !composerOpen[active.id] && (
              <TouchKeyBar
                ctrl={ctrlLatch}
                onCtrl={() => setCtrlLatch((v) => nextLatch("ctrl", v))}
                onKey={sendBarKey}
              />
            )}
            {!composerOpen[active.id] && (
              <button
                id="composer-strip"
                onClick={() => toggleComposer()}
                className="group flex h-8 shrink-0 items-center gap-2 border-t border-line bg-bg1 px-3 text-left transition-colors hover:bg-bg2/60 pointer-coarse:h-11"
              >
                <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 shrink-0 text-fg-muted transition-colors group-hover:text-mint pointer-coarse:h-4.5 pointer-coarse:w-4.5" fill="none" stroke="currentColor" strokeWidth="1.5">
                  <rect x="1.5" y="4" width="13" height="8" rx="1.5" />
                  <path d="M4 9.5h8" strokeLinecap="round" />
                </svg>
                <span className="truncate font-mono text-[12px] text-fg-muted/70 transition-colors group-hover:text-fg-muted pointer-coarse:text-sm">
                  {t("composerStripHint")}
                </span>
                <div className="flex-1" />
                {coarsePointer ? (
                  /* A shortcut chip means nothing on touch — show what a tap
                     on this strip does instead. */
                  <span
                    id="composer-open-touch"
                    className="shrink-0 rounded-md border border-line px-2 py-0.5 font-mono text-[11px] text-fg-muted pointer-coarse:px-3 pointer-coarse:py-1.5 pointer-coarse:text-sm"
                  >
                    {t("composerOpenTouch")}
                  </span>
                ) : (
                  <Kbd>{modShiftCombo("k")}</Kbd>
                )}
              </button>
            )}
            {composerOpen[active.id] && (
              <InputBar
                key={active.id}
                sessionId={active.id}
                root={active.cwd}
                app={composerApps[active.id] ?? null}
                value={composerDrafts[active.id] ?? ""}
                onChange={(v) => setComposerDrafts((d) => ({ ...d, [active.id]: v }))}
                focusNonce={composerFocusNonce}
                focusConsumed={composerFocusConsumedRef.current}
                onFocusConsumed={(n) => (composerFocusConsumedRef.current = n)}
                onSend={(text, submit) => void sendToForegroundApp(text, submit)}
                onError={toast}
                onClose={() => {
                  setComposerOpen((m) => ({ ...m, [active.id]: false }));
                  termActions.current?.focus();
                }}
              />
            )}
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
