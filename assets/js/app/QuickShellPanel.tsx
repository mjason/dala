import React, { useEffect, useRef } from "react";
import TerminalView, { type TerminalActions } from "./TerminalView";
import ResizeHandle from "./ResizeHandle";
import { useI18n } from "./i18n";
import { isTopWindow, popWindow, pushWindow } from "./shortcuts";
import { historyLines, shortPath } from "./util";
import type { Session } from "./Sidebar";

type Props = {
  sessions: Session[];
  active: Session;
  onSelect: (id: string) => void;
  onAdd: () => void;
  maximized: boolean;
  onToggleMax: () => void;
  onClose: () => void;
  /** Desktop width in px (draggable via the left-edge handle). */
  width: number;
  onResize: (clientX: number) => void;
  onResetWidth?: () => void;
  actionsRef: React.MutableRefObject<TerminalActions | null>;
  onError: (message: string) => void;
};

/**
 * The quick shells: disposable terminals in an overlay panel (like the file
 * drawer), so grabbing a shell for vim/git never rearranges the session
 * list. Tabs (⚡1 2 …) hold multiple shells; closing the panel (Esc, ✕ or
 * the toggle) destroys them all — scratch paper, nothing is kept.
 */
export default function QuickShellPanel({
  sessions,
  active,
  onSelect,
  onAdd,
  maximized,
  onToggleMax,
  onClose,
  width,
  onResize,
  onResetWidth,
  actionsRef,
  onError,
}: Props) {
  const { t } = useI18n();

  // The panel is a layer on the window stack: Escape closes the topmost
  // layer only (a fullscreen composer underneath keeps its Esc for later).
  // This window-level handler covers focus anywhere in the panel; Esc inside
  // the terminal goes through TerminalView's onEscape instead (it must not
  // fire on the alternate buffer — vim keeps its Escape key).
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const token = pushWindow();
    const handler = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented || !isTopWindow(token)) return;
      e.preventDefault();
      closeRef.current();
    };
    window.addEventListener("keydown", handler);
    return () => {
      window.removeEventListener("keydown", handler);
      popWindow(token);
    };
  }, []);

  return (
    <div
      id="quick-shell-panel"
      className={`fixed z-40 flex flex-col bg-bg0 shadow-2xl shadow-black/60 ${
        maximized ? "inset-0" : "inset-y-0 right-0 border-l border-line"
      }`}
      style={maximized ? undefined : { width, maxWidth: "100vw" }}
    >
      {!maximized && (
        <ResizeHandle id="quick-shell-resize" edge="left" onResize={onResize} onReset={onResetWidth} />
      )}
      {/* h-11 matches the main header, so the split line tops align.
          Esc anywhere in the panel (header included) closes it via the
          window-stack handler above. */}
      <header className="flex h-11 shrink-0 items-center gap-2 border-b border-line bg-bg1 px-3">
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
      <div className="min-h-0 flex-1 overflow-hidden">
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
