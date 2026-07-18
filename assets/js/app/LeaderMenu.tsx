import React, { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useI18n } from "./i18n";
import type { Messages } from "./i18n/locales";
import { formatCombo, loadBindings } from "./keybindings";
import { shortPath } from "./util";

/**
 * Spacemacs-style which-key menu: the leader chord (Settings → Shortcuts,
 * default ⌥Space) opens this overlay; single keys then navigate groups and
 * run actions. Every entry also shows the action's direct shortcut when one
 * exists — the menu doubles as the shortcut cheat-sheet.
 */

type LabelKey = keyof Messages;

type Leaf = {
  key: string;
  labelKey: LabelKey;
  action: string;
  bindingId?: string;
};
/** Opens the session picker view instead of running an App action. */
type PickerLeaf = { key: string; labelKey: LabelKey; picker: true };
type Group = {
  key: string;
  labelKey: LabelKey;
  children: (Leaf | PickerLeaf)[];
};
export type LeaderNode = Leaf | PickerLeaf | Group;

export type SessionOption = {
  id: string;
  name: string;
  cwd: string;
  active: boolean;
};

/** One keystroke per session: 1-9, then letters (the picker owns the keyboard). */
export const SESSION_KEYS = "123456789abcdefghijklmnopqrstuvwxyz".split("");

export const LEADER_TREE: LeaderNode[] = [
  {
    key: "s",
    labelKey: "leaderSessions",
    children: [
      { key: "s", labelKey: "leaderSwitchSession", picker: true },
      { key: "n", labelKey: "newTerminal", action: "newSession" },
      {
        key: "q",
        labelKey: "kbQuickShell",
        action: "quickShell",
        bindingId: "quickShell",
      },
      {
        key: "r",
        labelKey: "kbRenameSession",
        action: "renameSession",
        bindingId: "renameSession",
      },
      { key: ",", labelKey: "sessionSettings", action: "sessionSettings" },
    ],
  },
  {
    // Window/rendering concerns: PTY size, repaint, competing viewers.
    key: "r",
    labelKey: "leaderRender",
    children: [
      { key: "f", labelKey: "refitWidth", action: "refit", bindingId: "refit" },
      {
        key: "x",
        labelKey: "resetTerminal",
        action: "resetTerminal",
        bindingId: "resetTerminal",
      },
      { key: "k", labelKey: "kickViewersAction", action: "kickViewers" },
    ],
  },
  {
    key: "p",
    labelKey: "leaderPanels",
    children: [
      { key: "e", labelKey: "kbDrawer", action: "drawer", bindingId: "drawer" },
      { key: "g", labelKey: "kbGit", action: "git", bindingId: "git" },
      {
        key: "b",
        labelKey: "kbSidebar",
        action: "sidebar",
        bindingId: "sidebar",
      },
    ],
  },
  {
    key: "c",
    labelKey: "leaderComposer",
    children: [
      {
        key: "c",
        labelKey: "kbComposer",
        action: "composer",
        bindingId: "composer",
      },
      {
        key: "v",
        labelKey: "speechStart",
        action: "voice",
        bindingId: "voice",
      },
      {
        key: "m",
        labelKey: "composerMention",
        action: "composerMention",
        bindingId: "composerMention",
      },
      {
        key: "a",
        labelKey: "composerAttach",
        action: "composerAttach",
        bindingId: "composerAttach",
      },
      {
        key: "s",
        labelKey: "stashCurrentInput",
        action: "composerStash",
        bindingId: "composerStash",
      },
    ],
  },
  {
    key: "t",
    labelKey: "kbFocusTerminal",
    action: "focusTerminal",
    bindingId: "focusTerminal",
  },
  {
    key: "f",
    labelKey: "quickOpenTitle",
    action: "quickOpen",
    bindingId: "quickOpen",
  },
];

/** Where the menu currently is: a group level, optionally the session picker. */
type View = { group: Group | null; picker: boolean };
const ROOT: View = { group: null, picker: false };

type Props = {
  open: boolean;
  onClose: () => void;
  /** Execute one leader action (App routes ids to the real handlers). */
  onAction: (action: string) => void;
  /** Sessions for the picker view (leader → s → s), in sidebar order. */
  sessions: SessionOption[];
  onSelectSession: (id: string) => void;
};

/** The shared row shell — level entries and picker rows look identical. */
const ROW_CLASS =
  "flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-[12px] leading-5 transition-colors hover:bg-bg2";

/** The shared key-cap chip — every row in every view uses this exact style. */
function KeyCap({ label }: { label: string }) {
  return (
    <kbd className="grid h-5 w-5 shrink-0 place-items-center rounded border border-line bg-bg0 font-term text-[11px] leading-none text-mint">
      {label}
    </kbd>
  );
}

export default function LeaderMenu({
  open,
  onClose,
  onAction,
  sessions,
  onSelectSession,
}: Props) {
  const { t } = useI18n();
  const [view, setView] = useState<View>(ROOT);
  // The handler reads the CURRENT level through a ref — side effects must
  // never live inside a setState updater (StrictMode double-invokes those).
  const viewRef = useRef<View>(ROOT);
  viewRef.current = view;
  const sessionsRef = useRef(sessions);
  sessionsRef.current = sessions;

  const panelRef = useRef<HTMLDivElement | null>(null);
  // Whether this open ended by RUNNING an action: then the action's own UI
  // (rename input, composer, revealed terminal, …) owns the focus —
  // restoring the previous focus would blur it right back shut.
  const ranActionRef = useRef(false);

  const selectSession = (id: string) => {
    ranActionRef.current = true;
    onSelectSession(id);
    onClose();
  };

  useEffect(() => {
    if (!open) return;
    setView(ROOT);
    viewRef.current = ROOT;
    ranActionRef.current = false;
    // Steal focus from whatever editable element had it (usually xterm's
    // hidden textarea): with focus on a non-editable panel the OS input
    // method never engages, so CJK IMEs cannot swallow the nav keys.
    const previous = document.activeElement as HTMLElement | null;
    panelRef.current?.focus();
    const handler = (e: KeyboardEvent) => {
      // The menu owns the keyboard entirely while open — nothing may leak
      // into the terminal underneath.
      if (["Shift", "Control", "Alt", "Meta"].includes(e.key)) return;
      // Mid-IME-composition keys are the input method's, not ours.
      if (e.isComposing || e.key === "Process") return;
      e.preventDefault();
      e.stopPropagation();
      const current = viewRef.current;
      if (e.key === "Escape") return onClose();
      if (e.key === "Backspace") {
        // One level at a time: picker → its group → root.
        return setView(
          current.picker ? { group: current.group, picker: false } : ROOT,
        );
      }
      if (current.picker) {
        const target = sessionsRef.current[SESSION_KEYS.indexOf(e.key)];
        if (target) selectSession(target.id);
        return;
      }
      const level: LeaderNode[] = current.group
        ? current.group.children
        : LEADER_TREE;
      const hit = level.find((node) => node.key === e.key);
      if (!hit) return;
      if ("children" in hit) {
        setView({ group: hit, picker: false });
      } else if ("picker" in hit) {
        setView({ group: current.group, picker: true });
      } else {
        ranActionRef.current = true;
        onAction(hit.action);
        onClose();
      }
    };
    window.addEventListener("keydown", handler, true);
    return () => {
      window.removeEventListener("keydown", handler, true);
      if (!ranActionRef.current) previous?.focus?.();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  if (!open) return null;

  const bindings = loadBindings();
  const level: LeaderNode[] = view.group ? view.group.children : LEADER_TREE;

  return createPortal(
    <div
      className="fixed inset-x-0 bottom-0 z-50 flex justify-center p-4"
      id="leader-menu"
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        className="w-full max-w-xl rounded-xl border border-line bg-bg1 font-mono shadow-2xl shadow-black/50 outline-none"
      >
        <div className="flex items-center gap-2 border-b border-line px-3 py-2 text-xs">
          <span className="font-kbd text-mint">
            {formatCombo(bindings.leader)}
          </span>
          {view.group && (
            <>
              <span className="text-fg-muted/60">›</span>
              <span className="text-fg">{t(view.group.labelKey)}</span>
            </>
          )}
          {view.picker && (
            <>
              <span className="text-fg-muted/60">›</span>
              <span className="text-fg">{t("leaderSwitchSession")}</span>
            </>
          )}
          <span className="flex-1" />
          <span className="text-[10px] text-fg-muted/60">
            <span className="font-kbd">Esc</span> {t("leaderClose")}
            {view.group || view.picker ? " · " : ""}
            {(view.group || view.picker) && <span className="font-kbd">⌫</span>}
            {view.group || view.picker ? ` ${t("leaderBack")}` : ""}
          </span>
        </div>
        {view.picker ? (
          <div
            id="leader-session-picker"
            className="grid max-h-72 grid-cols-1 gap-x-4 gap-y-0.5 overflow-y-auto px-3 py-2 sm:grid-cols-2"
          >
            {sessions.slice(0, SESSION_KEYS.length).map((session, index) => (
              <button
                key={session.id}
                data-session-key={SESSION_KEYS[index]}
                onClick={() => selectSession(session.id)}
                aria-current={session.active || undefined}
                className={ROW_CLASS}
              >
                <KeyCap label={SESSION_KEYS[index]} />
                <span
                  className={[
                    "min-w-0 flex-1 truncate",
                    session.active ? "text-mint" : "text-fg",
                  ].join(" ")}
                >
                  {session.name}
                </span>
                <span className="shrink-0 text-[10px] text-fg-muted/60">
                  {shortPath(session.cwd, 22)}
                </span>
                {session.active && (
                  <span
                    className="h-1.5 w-1.5 shrink-0 rounded-full bg-mint"
                    aria-hidden
                  />
                )}
              </button>
            ))}
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-x-4 gap-y-0.5 px-3 py-2 sm:grid-cols-3">
            {level.map((node) => {
              const group = "children" in node;
              const picker = "picker" in node;
              const combo =
                !group && !picker && (node as Leaf).bindingId
                  ? bindings[(node as Leaf).bindingId!]
                  : null;
              return (
                <button
                  key={node.key}
                  data-leader-key={node.key}
                  onClick={() => {
                    if (group) {
                      setView({ group: node as Group, picker: false });
                    } else if (picker) {
                      setView({ group: view.group, picker: true });
                    } else {
                      ranActionRef.current = true;
                      onAction((node as Leaf).action);
                      onClose();
                    }
                  }}
                  className={ROW_CLASS}
                >
                  <KeyCap label={node.key} />
                  <span className="min-w-0 flex-1 truncate text-fg">
                    {t(node.labelKey)}
                  </span>
                  {group || picker ? (
                    <span className="shrink-0 text-[11px] text-fg-muted/60">
                      ›
                    </span>
                  ) : (
                    combo && (
                      <span className="shrink-0 font-kbd text-[10px] text-fg-muted/60">
                        {formatCombo(combo)}
                      </span>
                    )
                  )}
                </button>
              );
            })}
          </div>
        )}
      </div>
    </div>,
    document.body,
  );
}
