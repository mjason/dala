import React, { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useI18n } from "./i18n";
import type { Messages } from "./i18n/locales";
import { formatCombo, loadBindings } from "./keybindings";

/**
 * Spacemacs-style which-key menu: the leader chord (Settings → Shortcuts,
 * default ⌥Space) opens this overlay; single keys then navigate groups and
 * run actions. Every entry also shows the action's direct shortcut when one
 * exists — the menu doubles as the shortcut cheat-sheet.
 */

type LabelKey = keyof Messages;

type Leaf = { key: string; labelKey: LabelKey; action: string; bindingId?: string };
type Group = { key: string; labelKey: LabelKey; children: Leaf[] };
export type LeaderNode = Leaf | Group;

export const LEADER_TREE: LeaderNode[] = [
  {
    key: "s",
    labelKey: "leaderSessions",
    children: [
      { key: "n", labelKey: "newTerminal", action: "newSession" },
      { key: "q", labelKey: "kbQuickShell", action: "quickShell", bindingId: "quickShell" },
      { key: "r", labelKey: "kbRenameSession", action: "renameSession", bindingId: "renameSession" },
      { key: ",", labelKey: "sessionSettings", action: "sessionSettings" },
    ],
  },
  {
    // Window/rendering concerns: PTY size, repaint, competing viewers.
    key: "r",
    labelKey: "leaderRender",
    children: [
      { key: "f", labelKey: "refitWidth", action: "refit", bindingId: "refit" },
      { key: "x", labelKey: "resetTerminal", action: "resetTerminal", bindingId: "resetTerminal" },
      { key: "k", labelKey: "kickViewersAction", action: "kickViewers" },
    ],
  },
  {
    key: "p",
    labelKey: "leaderPanels",
    children: [
      { key: "e", labelKey: "kbDrawer", action: "drawer", bindingId: "drawer" },
      { key: "g", labelKey: "kbGit", action: "git", bindingId: "git" },
      { key: "b", labelKey: "kbSidebar", action: "sidebar", bindingId: "sidebar" },
    ],
  },
  {
    key: "c",
    labelKey: "leaderComposer",
    children: [
      { key: "c", labelKey: "kbComposer", action: "composer", bindingId: "composer" },
      { key: "v", labelKey: "speechStart", action: "voice", bindingId: "voice" },
      { key: "m", labelKey: "composerMention", action: "composerMention", bindingId: "composerMention" },
      { key: "a", labelKey: "composerAttach", action: "composerAttach", bindingId: "composerAttach" },
      { key: "s", labelKey: "stashCurrentInput", action: "composerStash", bindingId: "composerStash" },
    ],
  },
  { key: "t", labelKey: "kbFocusTerminal", action: "focusTerminal", bindingId: "focusTerminal" },
  { key: "f", labelKey: "quickOpenTitle", action: "quickOpen", bindingId: "quickOpen" },
];

type Props = {
  open: boolean;
  onClose: () => void;
  /** Execute one leader action (App routes ids to the real handlers). */
  onAction: (action: string) => void;
};

export default function LeaderMenu({ open, onClose, onAction }: Props) {
  const { t } = useI18n();
  const [path, setPath] = useState<Group | null>(null);
  // The handler reads the CURRENT level through a ref — side effects must
  // never live inside a setState updater (StrictMode double-invokes those).
  const pathRef = useRef<Group | null>(null);
  pathRef.current = path;

  const panelRef = useRef<HTMLDivElement | null>(null);
  // Whether this open ended by RUNNING an action: then the action's own UI
  // (rename input, composer, …) owns the focus — restoring the previous
  // focus would blur it right back shut.
  const ranActionRef = useRef(false);

  useEffect(() => {
    if (!open) return;
    setPath(null);
    pathRef.current = null;
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
      if (e.key === "Escape") return onClose();
      if (e.key === "Backspace") return setPath(null);
      const level: LeaderNode[] = pathRef.current ? pathRef.current.children : LEADER_TREE;
      const hit = level.find((node) => node.key === e.key);
      if (!hit) return;
      if ("children" in hit) {
        setPath(hit);
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
  const level: LeaderNode[] = path ? path.children : LEADER_TREE;

  return createPortal(
    <div className="fixed inset-x-0 bottom-0 z-50 flex justify-center p-4" id="leader-menu">
      <div
        ref={panelRef}
        tabIndex={-1}
        className="w-full max-w-xl rounded-xl border border-line bg-bg1 font-mono shadow-2xl shadow-black/50 outline-none"
      >
        <div className="flex items-center gap-2 border-b border-line px-3 py-2 text-xs">
          <span className="font-kbd text-mint">{formatCombo(bindings.leader)}</span>
          {path && (
            <>
              <span className="text-fg-muted/60">›</span>
              <span className="text-fg">{t(path.labelKey)}</span>
            </>
          )}
          <span className="flex-1" />
          <span className="text-[10px] text-fg-muted/60">
            <span className="font-kbd">Esc</span> {t("leaderClose")}
            {path ? " · " : ""}
            {path && <span className="font-kbd">⌫</span>}
            {path ? ` ${t("leaderBack")}` : ""}
          </span>
        </div>
        <div className="grid grid-cols-2 gap-x-4 gap-y-0.5 px-3 py-2 sm:grid-cols-3">
          {level.map((node) => {
            const group = "children" in node;
            const combo = !group && node.bindingId ? bindings[node.bindingId] : null;
            return (
              <button
                key={node.key}
                data-leader-key={node.key}
                onClick={() => {
                  if (group) {
                    setPath(node as Group);
                  } else {
                    ranActionRef.current = true;
                    onAction((node as Leaf).action);
                    onClose();
                  }
                }}
                className="flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-[12px] leading-5 transition-colors hover:bg-bg2"
              >
                <kbd className="grid h-5 w-5 shrink-0 place-items-center rounded border border-line bg-bg0 font-term text-[11px] leading-none text-mint">
                  {node.key}
                </kbd>
                <span className="min-w-0 flex-1 truncate text-fg">{t(node.labelKey)}</span>
                {group ? (
                  <span className="shrink-0 text-[11px] text-fg-muted/60">›</span>
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
      </div>
    </div>,
    document.body,
  );
}
