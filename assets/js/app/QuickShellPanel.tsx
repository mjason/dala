import React from "react";
import TerminalView from "./TerminalView";
import { useI18n } from "./i18n";
import { historyLines, shortPath } from "./util";
import type { Session } from "./Sidebar";

type TerminalActions = { reset: () => void; refit: () => void; focus: () => void };

type Props = {
  session: Session;
  maximized: boolean;
  onToggleMax: () => void;
  onClose: () => void;
  actionsRef: React.MutableRefObject<TerminalActions | null>;
  onError: (message: string) => void;
};

/**
 * The quick shell: an ephemeral terminal in an overlay panel (like the file
 * drawer), so grabbing a shell for vim/git never rearranges the session
 * list. Closing the panel keeps the shell running; `exit`/Ctrl+D inside it
 * destroys the session for good.
 */
export default function QuickShellPanel({
  session,
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
      <header className="flex h-10 shrink-0 items-center gap-2 border-b border-line bg-bg1 px-3">
        <span className="text-sm text-mint">⚡</span>
        <span className="shrink-0 font-mono text-sm text-fg">{t("quickShellTitle")}</span>
        <span
          className="hidden truncate font-mono text-xs text-fg-muted sm:block"
          title={session.cwd}
        >
          {shortPath(session.cwd, 48)}
        </span>
        <div className="flex-1" />
        <span className="hidden font-mono text-[11px] text-fg-muted/70 md:block">
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
          sessionId={session.id}
          scrollbackLines={historyLines(session.scrollbackLimit)}
          actionsRef={actionsRef}
          onError={onError}
        />
      </div>
    </div>
  );
}
