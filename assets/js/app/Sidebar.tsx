import React, { useRef, useState } from "react";
import type { SessionUpdatedPayload } from "../ash_types";
import { authEnabled, userEmail } from "./meta";
import { beforeIdFor, insertionIndex } from "./reorder";
import { shortPath } from "./util";
import { LOCALE_NAMES, useI18n } from "./i18n";
import type { Locale } from "./i18n";
import UpdateCheck from "./UpdateCheck";
import ResizeHandle from "./ResizeHandle";
import { Select } from "./ui";

export type Session = SessionUpdatedPayload;

type Props = {
  sessions: Session[];
  activeId: string | null;
  connected: boolean;
  creating: boolean;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onOpenSettings: (id: string) => void;
  onDelete: (id: string) => void;
  /** Persist a drag: move `id` before `beforeId` (null = to the end). */
  onReorder: (id: string, beforeId: string | null) => void;
  /** Session whose row is currently being renamed in place (⌥⌘R / double-click). */
  renamingId: string | null;
  /** Open (id) or close (null) the inline rename editor. */
  onRenameStart: (id: string | null) => void;
  /** Persist a new name (already trimmed, non-empty and actually changed). */
  onRename: (id: string, name: string) => void;
  /** Agent activity per session (OSC 777 events): overrides the status dot. */
  agentStatus?: Record<string, { state: "working" | "attention" | "done" }>;
  /** Desktop width in px (draggable via the right-edge handle). */
  width?: number;
  onResize?: (clientX: number) => void;
  onResetWidth?: () => void;
};

export default function Sidebar({
  sessions,
  activeId,
  connected,
  creating,
  onSelect,
  onCreate,
  onOpenSettings,
  onDelete,
  onReorder,
  renamingId,
  onRenameStart,
  onRename,
  agentStatus,
  width,
  onResize,
  onResetWidth,
}: Props) {
  const { locale, t, setLocale } = useI18n();

  // Drag-to-reorder (pointer events, dedicated handle — HTML5 dnd is poor
  // on touch and would hijack list panning). While a drag is live, `drag`
  // holds the insertion slot (see reorder.ts) for the indicator line.
  // Known limitation: no edge auto-scroll — dragging in an overflowing
  // list cannot reach rows outside the current viewport (the wheel still
  // scrolls mid-drag, so it stays workable).
  const listRef = useRef<HTMLElement | null>(null);
  const [drag, setDrag] = useState<{ id: string; slot: number } | null>(null);
  // The list can change UNDER a live drag (another device reorders, a
  // session exits/appears): everything resolved at drop time must read the
  // CURRENT list, never the one frozen into the pointerdown closure.
  const sessionsRef = useRef(sessions);
  sessionsRef.current = sessions;

  const startDrag = (e: React.PointerEvent, id: string) => {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    e.preventDefault(); // no text selection while dragging across rows
    const pointerId = e.pointerId;
    const handle = e.currentTarget as HTMLElement;
    // Keep receiving moves even when the pointer leaves the handle (jsdom
    // has no setPointerCapture; window listeners below still see events).
    try {
      handle.setPointerCapture?.(pointerId);
    } catch {
      /* not supported */
    }
    const startY = e.clientY;
    let slot: number | null = null; // null until the movement threshold

    const midpoints = () =>
      Array.from(listRef.current?.querySelectorAll<HTMLElement>("[data-session-row]") ?? []).map(
        (row) => {
          const box = row.getBoundingClientRect();
          return box.top + box.height / 2;
        },
      );

    const cleanup = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onCancel);
      window.removeEventListener("keydown", onKeyDown);
      setDrag(null);
    };
    const onMove = (ev: PointerEvent) => {
      if (ev.pointerId !== pointerId) return;
      if (slot === null && Math.abs(ev.clientY - startY) < 5) return;
      // Fresh index on every move: the midpoints come from the live DOM,
      // so the dragged row's index must come from the live list too.
      const index = sessionsRef.current.findIndex((s) => s.id === id);
      if (index === -1) return cleanup(); // dragged session vanished
      slot = insertionIndex(midpoints(), index, ev.clientY);
      setDrag({ id, slot });
    };
    const onUp = (ev: PointerEvent) => {
      if (ev.pointerId !== pointerId) return;
      cleanup();
      if (slot === null) return; // never crossed the threshold: a plain tap
      // Resolve the committed neighbour against the CURRENT list — the drop
      // must land where the indicator points now, not where the rows were
      // at pointerdown.
      const list = sessionsRef.current;
      const index = list.findIndex((s) => s.id === id);
      if (index === -1) return; // dragged session vanished mid-drag
      const beforeId = beforeIdFor(list, id, slot);
      // Dropped back onto its own slot: nothing to persist.
      if (beforeId !== (list[index + 1]?.id ?? null)) onReorder(id, beforeId);
    };
    const onCancel = (ev: PointerEvent) => {
      if (ev.pointerId === pointerId) cleanup();
    };
    // Escape abandons the drag without committing (pointerup after the
    // cleanup is a no-op — its listener is already gone).
    const onKeyDown = (ev: KeyboardEvent) => {
      if (ev.key === "Escape") cleanup();
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onCancel);
    window.addEventListener("keydown", onKeyDown);
  };

  // Row carrying the insertion indicator (undefined = none, null = after
  // the last row).
  const dropBeforeId = drag ? beforeIdFor(sessions, drag.id, drag.slot) : undefined;

  return (
    <aside
      className="relative flex h-full w-64 shrink-0 flex-col border-r border-line bg-bg1 md:w-[var(--panel-w,16rem)]"
      style={width ? ({ "--panel-w": `${width}px` } as React.CSSProperties) : undefined}
    >
      {onResize && (
        <ResizeHandle id="sidebar-resize" edge="right" onResize={onResize} onReset={onResetWidth} />
      )}
      <div className="flex items-center gap-2 px-4 pt-4 pb-3">
        <span className="font-mono text-[15px] font-semibold tracking-widest text-fg">DALA</span>
        <span
          className={`ml-1 inline-block h-1.5 w-1.5 rounded-full transition-colors ${
            connected ? "bg-mint" : "bg-danger animate-pulse"
          }`}
          title={connected ? t("connected") : t("reconnecting")}
        />
        <div className="flex-1" />
        <button
          id="new-session-button"
          onClick={onCreate}
          disabled={creating}
          className="grid h-7 w-7 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:border-fg-muted hover:text-fg disabled:opacity-50 pointer-coarse:h-10 pointer-coarse:w-10"
          title={t("newTerminal")}
        >
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 pointer-coarse:h-4.5 pointer-coarse:w-4.5" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M8 3v10M3 8h10" strokeLinecap="round" />
          </svg>
        </button>
      </div>

      <nav id="session-list" ref={listRef} className="flex-1 overflow-y-auto px-2 pb-2">
        {sessions.length === 0 && (
          <div className="mt-10 px-3 text-center text-[13px] leading-6 text-fg-muted">
            {t("noTerminalsYet")}
            <br />
            <button onClick={onCreate} className="text-mint hover:underline">
              + {t("newTerminal")}
            </button>
          </div>
        )}
        {sessions.map((s, index) => {
          const active = s.id === activeId;
          return (
            <div
              key={s.id}
              data-session-row={s.id}
              onClick={() => onSelect(s.id)}
              className={`group relative mb-0.5 flex cursor-pointer items-center gap-2 rounded-lg py-2 pr-2.5 pl-1 transition-colors pointer-coarse:min-h-11 ${
                active ? "bg-bg2 text-fg" : "text-fg-muted hover:bg-bg2/60 hover:text-fg"
              } ${drag?.id === s.id ? "opacity-50" : ""}`}
            >
              {dropBeforeId === s.id && (
                <span className="pointer-events-none absolute inset-x-1 -top-[2px] h-0.5 rounded-full bg-mint" />
              )}
              {dropBeforeId === null && drag?.id !== s.id && index === sessions.length - 1 && (
                <span className="pointer-events-none absolute inset-x-1 -bottom-[2px] h-0.5 rounded-full bg-mint" />
              )}
              <button
                data-drag-session={s.id}
                aria-label={t("dragToReorder")}
                title={t("dragToReorder")}
                onClick={(e) => e.stopPropagation()}
                onPointerDown={(e) => {
                  e.stopPropagation();
                  startDrag(e, s.id);
                }}
                className="flex h-6 w-4 shrink-0 cursor-grab touch-none items-center justify-center rounded text-transparent transition-colors group-hover:text-fg-muted active:cursor-grabbing pointer-coarse:h-9 pointer-coarse:w-6 pointer-coarse:text-fg-muted/60"
              >
                <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 pointer-coarse:h-4 pointer-coarse:w-4" fill="currentColor">
                  <circle cx="5.5" cy="3.5" r="1.15" />
                  <circle cx="10.5" cy="3.5" r="1.15" />
                  <circle cx="5.5" cy="8" r="1.15" />
                  <circle cx="10.5" cy="8" r="1.15" />
                  <circle cx="5.5" cy="12.5" r="1.15" />
                  <circle cx="10.5" cy="12.5" r="1.15" />
                </svg>
              </button>
              <span
                className={`h-1.5 w-1.5 shrink-0 rounded-full ${(() => {
                  const agent = agentStatus?.[s.id]?.state;
                  if (agent === "attention") return "animate-pulse bg-[#d9a860]";
                  if (agent === "working") return "animate-pulse bg-mint";
                  if (agent === "done") return "bg-[#6d9fd6]";
                  return s.status === "running" ? "bg-mint" : "bg-fg-muted/50";
                })()}`}
              />
              <div className="min-w-0 flex-1">
                {renamingId === s.id ? (
                  <RenameInput
                    id={s.id}
                    name={s.name}
                    label={t("kbRenameSession")}
                    onCommit={(next) => {
                      if (next && next !== s.name) onRename(s.id, next);
                      onRenameStart(null);
                    }}
                    onCancel={() => onRenameStart(null)}
                  />
                ) : (
                  <div
                    className="truncate font-mono text-sm"
                    title={t("kbRenameSession")}
                    onDoubleClick={(e) => {
                      e.stopPropagation();
                      onRenameStart(s.id);
                    }}
                  >
                    {s.name}
                  </div>
                )}
                <div className="truncate font-mono text-xs text-fg-muted/80">
                  {shortPath(s.cwd, 28)}
                </div>
              </div>
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  onOpenSettings(s.id);
                }}
                className="hidden h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:text-fg group-hover:grid pointer-coarse:grid pointer-coarse:h-9 pointer-coarse:w-9"
                title={t("sessionSettings")}
              >
                <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 pointer-coarse:h-4.5 pointer-coarse:w-4.5" fill="currentColor">
                  <circle cx="3" cy="8" r="1.3" />
                  <circle cx="8" cy="8" r="1.3" />
                  <circle cx="13" cy="8" r="1.3" />
                </svg>
              </button>
              <button
                data-delete-session={s.id}
                onClick={(e) => {
                  e.stopPropagation();
                  onDelete(s.id);
                }}
                className="hidden h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:text-danger group-hover:grid pointer-coarse:grid pointer-coarse:h-9 pointer-coarse:w-9"
                title={t("deleteSession")}
              >
                <svg
                  viewBox="0 0 16 16"
                  className="h-3.5 w-3.5 pointer-coarse:h-4.5 pointer-coarse:w-4.5"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.5"
                >
                  <path d="m4 4 8 8m0-8-8 8" strokeLinecap="round" />
                </svg>
              </button>
            </div>
          );
        })}
      </nav>

      <footer className="space-y-2 border-t border-line px-4 py-3 text-xs text-fg-muted">
        <div className="flex items-center justify-between gap-2">
          {authEnabled ? (
            <>
              <span className="truncate font-mono" title={userEmail ?? ""}>
                {userEmail}
              </span>
              <a href="/sign-out" className="shrink-0 transition-colors hover:text-fg">
                {t("signOut")}
              </a>
            </>
          ) : (
            <span className="font-mono">{t("localMode")}</span>
          )}
        </div>
        <UpdateCheck />
        <Select
          id="language-select"
          aria-label={t("language")}
          value={locale}
          onChange={(e) => setLocale(e.target.value as Locale)}
        >
          {(Object.keys(LOCALE_NAMES) as Locale[]).map((code) => (
            <option key={code} value={code}>
              {LOCALE_NAMES[code]}
            </option>
          ))}
        </Select>
      </footer>
    </aside>
  );
}

/**
 * In-place name editor for one sidebar row: Enter and blur commit, Escape
 * cancels. Escape is swallowed here (stopPropagation + preventDefault) — the
 * editor is not a "window" on the Esc stack, so it must not pop one.
 */
function RenameInput({
  id,
  name,
  label,
  onCommit,
  onCancel,
}: {
  id: string;
  name: string;
  label: string;
  onCommit: (name: string) => void;
  onCancel: () => void;
}) {
  // Enter commits and then blurs: the first outcome wins, the blur is a no-op.
  const settled = useRef(false);
  const commit = (value: string) => {
    if (settled.current) return;
    settled.current = true;
    onCommit(value.trim());
  };
  const cancel = () => {
    if (settled.current) return;
    settled.current = true;
    onCancel();
  };

  return (
    <input
      data-rename-session={id}
      aria-label={label}
      defaultValue={name}
      autoFocus
      spellCheck={false}
      onFocus={(e) => e.currentTarget.select()}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          commit(e.currentTarget.value);
        } else if (e.key === "Escape") {
          e.preventDefault();
          cancel();
        }
      }}
      onBlur={(e) => commit(e.currentTarget.value)}
      className="w-full rounded border border-mint/60 bg-bg0 px-1 py-px font-mono text-sm text-fg outline-none"
    />
  );
}
