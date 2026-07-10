import React from "react";
import TerminalView from "./TerminalView";
import { useI18n } from "./i18n";
import { historyLines, shortPath } from "./util";
import type { Session } from "./Sidebar";

type TerminalActions = { reset: () => void; refit: () => void; focus: () => void };

type Props = {
  sessions: Session[];
  active: Session;
  onSelect: (id: string) => void;
  onAdd: () => void;
  maximized: boolean;
  onToggleMax: () => void;
  onClose: () => void;
  actionsRef: React.MutableRefObject<TerminalActions | null>;
  onError: (message: string) => void;
};

/**
 * The quick shells: ephemeral terminals in an overlay panel (like the file
 * drawer), so grabbing a shell for vim/git never rearranges the session
 * list. Tabs (⚡1 ⚡2 …) hold multiple shells; Esc or the toggle hides the
 * panel keeping them alive; `exit`/Ctrl+D inside one destroys it for good.
 */
export default function QuickShellPanel({
  sessions,
  active,
  onSelect,
  onAdd,
  maximized,
  onToggleMax,
  onClose,
  actionsRef,
  onError,
}: Props) {
  const { t } = useI18n();

  return (
    <div
      id="quick-shell-panel"
      className={`fixed z-40 flex flex-col bg-bg0 shadow-2xl shadow-black/60 ${
        maximized
          ? "inset-0"
          : "inset-y-0 right-0 w-full border-l border-line sm:w-[min(52rem,78vw)]"
      }`}
    >
      {/* h-11 matches the main header, so the split line tops align. */}
      <header
        className="flex h-11 shrink-0 items-center gap-2 border-b border-line bg-bg1 px-3"
        onKeyDown={(e) => {
          // Esc with focus on the header buttons/tabs also hides the panel;
          // Esc inside the terminal is handled by TerminalView's onEscape.
          if (e.key === "Escape") onClose();
        }}
      >
        <span className="text-sm text-mint">⚡</span>
        <div className="flex min-w-0 items-center gap-1 overflow-x-auto">
          {sessions.map((s, i) => (
            <button
              key={s.id}
              data-quick-tab={s.id}
              onClick={() => onSelect(s.id)}
              title={s.cwd}
              className={`shrink-0 rounded-md border px-2 py-1 font-mono text-[11px] transition-colors ${
                s.id === active.id
                  ? "border-mint/50 bg-bg2 text-mint"
                  : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
              }`}
            >
              {i + 1}
            </button>
          ))}
        </div>
        <button
          id="quick-shell-add"
          onClick={onAdd}
          className="grid h-6 w-6 shrink-0 place-items-center rounded border border-line text-fg-muted transition-colors hover:border-mint/60 hover:text-mint"
          title={t("quickShellTitle")}
        >
          <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M8 3v10M3 8h10" strokeLinecap="round" />
          </svg>
        </button>
        <span
          className="hidden truncate font-mono text-xs text-fg-muted sm:block"
          title={active.cwd}
        >
          {shortPath(active.cwd, 40)}
        </span>
        <div className="flex-1" />
        <span className="hidden font-mono text-[11px] text-fg-muted/70 lg:block">
          {t("quickShellHint")}
        </span>
        <button
          id="quick-shell-max"
          onClick={onToggleMax}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:text-fg"
          title={maximized ? t("restore") : t("maximize")}
        >
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
            {maximized ? (
              <>
                <path d="M6 2v4H2" strokeLinecap="round" />
                <path d="M10 14v-4h4" strokeLinecap="round" />
              </>
            ) : (
              <>
                <path d="M9 2h5v5" strokeLinecap="round" />
                <path d="M7 14H2V9" strokeLinecap="round" />
              </>
            )}
          </svg>
        </button>
        <button
          id="quick-shell-close"
          onClick={onClose}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:text-fg"
          title={t("close")}
        >
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="m3 3 10 10M13 3 3 13" strokeLinecap="round" />
          </svg>
        </button>
      </header>
      <div className="min-h-0 flex-1">
        <TerminalView
          key={active.id}
          sessionId={active.id}
          scrollbackLines={historyLines(active.scrollbackLimit)}
          actionsRef={actionsRef}
          onError={onError}
          onEscape={onClose}
        />
      </div>
    </div>
  );
}
