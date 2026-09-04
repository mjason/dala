import React from "react";
import { useI18n } from "./i18n";
import type { Session } from "./Sidebar";

type Props = {
  /** Main shell first, then the attached shells (see sessionTabs.tabsFor). */
  tabs: Session[];
  activeId: string;
  onSelect: (id: string) => void;
  onAdd: () => void;
  /** Only attached shells can be closed here; the main shell is the session. */
  onClose: (id: string) => void;
};

/**
 * The tab strip above the terminal: a session's main shell plus the shells
 * attached to it. Switching a tab swaps the whole terminal area, so a long
 * task (`rails s`) keeps running in its own tab while you work in another.
 */
export default function SessionTabs({ tabs, activeId, onSelect, onAdd, onClose }: Props) {
  const { t } = useI18n();
  if (tabs.length === 0) return null;

  return (
    <div
      id="session-tabs"
      className="flex h-8 shrink-0 items-center gap-1 overflow-x-auto border-b border-line bg-bg1 px-2"
    >
      {tabs.map((tab, index) => {
        const isActive = tab.id === activeId;
        const isMain = index === 0;

        return (
          <div
            key={tab.id}
            data-session-tab={tab.id}
            data-active={isActive}
            className={`group flex h-6 shrink-0 items-center gap-1 rounded-md border pl-2 transition-colors ${
              isMain ? "pr-2" : "pr-1"
            } ${
              isActive
                ? "border-mint/50 bg-bg2 text-mint"
                : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
            } ${tab.status === "exited" ? "opacity-60" : ""}`}
          >
            <button
              onClick={() => onSelect(tab.id)}
              title={tab.cwd}
              className="max-w-[12rem] truncate font-mono text-[11px]"
            >
              {tab.name}
            </button>
            {!isMain && (
              <button
                data-close-tab={tab.id}
                onClick={() => onClose(tab.id)}
                title={t("closeShellTab")}
                className="grid h-4 w-4 place-items-center rounded text-fg-muted/60 opacity-0 transition-opacity hover:text-danger group-hover:opacity-100"
              >
                <svg viewBox="0 0 16 16" className="h-2.5 w-2.5" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="m3 3 10 10M13 3 3 13" strokeLinecap="round" />
                </svg>
              </button>
            )}
          </div>
        );
      })}
      <button
        id="session-tab-add"
        onClick={onAdd}
        title={t("newShellTab")}
        className="grid h-5 w-5 shrink-0 place-items-center rounded border border-line text-fg-muted transition-colors hover:border-mint/60 hover:text-mint"
      >
        <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
          <path d="M8 3v10M3 8h10" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  );
}
