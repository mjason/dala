import React, { useEffect, useRef, useState } from "react";
import type { SessionUpdatedPayload } from "../ash_types";
import { authEnabled, userEmail } from "./meta";
import { beforeIdFor, insertionIndex } from "./reorder";
import { groupNames, groupSessions, rangeBetween } from "./sessionGroups";
import { shortPath } from "./util";
import { LOCALE_NAMES, useI18n } from "./i18n";
import type { Locale } from "./i18n";
import UpdateCheck from "./UpdateCheck";
import { RenameInput } from "./RenameInput";
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
  /** Batch delete for the multi-selection (App confirms first). */
  onDeleteMany: (ids: string[]) => void;
  /** Assign sessions to a named group (null = ungroup). */
  onSetGroup: (ids: string[], group: string | null) => void;
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
  onDeleteMany,
  onSetGroup,
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

  // ---- Grouping (auto, by cwd) + collapse persistence ----------------------
  const [collapsed, setCollapsed] = useState<Set<string>>(() => {
    try {
      return new Set(JSON.parse(localStorage.getItem("dala:collapsed-session-groups") ?? "[]"));
    } catch {
      return new Set();
    }
  });
  const toggleGroup = (key: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      localStorage.setItem("dala:collapsed-session-groups", JSON.stringify([...next]));
      return next;
    });

  const groups = groupSessions(sessions);
  // The rows actually on screen, in render order — drag geometry, drop
  // resolution and shift-ranges must all speak THIS list, not the full one
  // (collapsed groups hide rows).
  const visibleSessions = groups.flatMap((g) =>
    g.key != null && collapsed.has(g.key) ? [] : g.sessions,
  );
  const visibleRef = useRef(visibleSessions);
  visibleRef.current = visibleSessions;

  // ---- Multi-selection (Ctrl/Cmd toggle, Shift range) ----------------------
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const anchorRef = useRef<string | null>(null);

  // Right-click menu — the discoverable path to multi-select and batch
  // delete (Ctrl/Shift-click alone is invisible to anyone not looking).
  const [ctxMenu, setCtxMenu] = useState<
    | {
        x: number;
        y: number;
        target: { kind: "session"; id: string } | { kind: "group"; key: string };
        /** "move" = second level: pick a destination group. */
        view?: "move";
      }
    | null
  >(null);
  // Naming dialog for "new group…" / "rename group" (ids get that name).
  const [groupModal, setGroupModal] = useState<{ ids: string[]; initial: string } | null>(null);

  useEffect(() => {
    if (!ctxMenu) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      e.preventDefault(); // one Esc closes one layer: the menu, not the selection
      setCtxMenu(null);
    };
    // Capture phase: the selection-clearing Escape listener below was
    // registered earlier and would otherwise run first.
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [ctxMenu]);

  const toggleSelect = (id: string) => {
    anchorRef.current = id;
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // Prune selections for sessions that no longer exist (deleted elsewhere).
  useEffect(() => {
    setSelected((prev) => {
      const alive = new Set(sessions.map((s) => s.id));
      const next = new Set([...prev].filter((id) => alive.has(id)));
      return next.size === prev.size ? prev : next;
    });
  }, [sessions]);

  // Esc clears the selection (only while one exists, and never from a field).
  useEffect(() => {
    if (selected.size === 0) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      const el = document.activeElement;
      if (
        el instanceof HTMLInputElement ||
        el instanceof HTMLTextAreaElement ||
        el instanceof HTMLSelectElement
      )
        return;
      setSelected(new Set());
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [selected.size]);

  const rowClick = (e: React.MouseEvent, id: string) => {
    if (e.metaKey || e.ctrlKey) {
      toggleSelect(id);
    } else if (e.shiftKey && anchorRef.current) {
      setSelected(
        new Set(
          rangeBetween(
            visibleRef.current.map((s) => s.id),
            anchorRef.current,
            id,
          ),
        ),
      );
    } else {
      anchorRef.current = id;
      if (selected.size > 0) setSelected(new Set());
      onSelect(id);
    }
  };

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
      // Fresh index on every move: the midpoints come from the live DOM
      // (visible rows only — collapsed groups hide theirs), so the dragged
      // row's index must come from the live VISIBLE list too.
      const index = visibleRef.current.findIndex((s) => s.id === id);
      if (index === -1) return cleanup(); // dragged session vanished
      slot = insertionIndex(midpoints(), index, ev.clientY);
      setDrag({ id, slot });
    };
    const onUp = (ev: PointerEvent) => {
      if (ev.pointerId !== pointerId) return;
      cleanup();
      if (slot === null) return; // never crossed the threshold: a plain tap
      // Resolve the committed neighbour against the CURRENT visible list —
      // the drop must land where the indicator points now.
      const list = visibleRef.current;
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
  // the last visible row).
  const dropBeforeId = drag ? beforeIdFor(visibleSessions, drag.id, drag.slot) : undefined;
  const lastVisibleId = visibleSessions[visibleSessions.length - 1]?.id;

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
        {groups.map((g, gi) => {
          const grouped = g.key != null;
          const isCollapsed = grouped && collapsed.has(g.key!);
          return (
            <React.Fragment key={g.key ?? `loose-${gi}`}>
              {grouped && (
                <button
                  data-session-group={g.key}
                  aria-expanded={!isCollapsed}
                  onClick={() => toggleGroup(g.key!)}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    setCtxMenu({ x: e.clientX, y: e.clientY, target: { kind: "group", key: g.key! } });
                  }}
                  title={g.key!}
                  className="mb-0.5 flex w-full items-center gap-1 rounded-md px-1.5 py-1 text-left font-mono text-[11px] text-fg-muted/80 transition-colors hover:bg-bg2/50 hover:text-fg-muted pointer-coarse:min-h-9"
                >
                  <svg
                    viewBox="0 0 16 16"
                    className={`h-3 w-3 shrink-0 transition-transform ${isCollapsed ? "" : "rotate-90"}`}
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.8"
                  >
                    <path d="M6 4l4 4-4 4" strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                  <span className="min-w-0 truncate">{g.key}</span>
                  <span className="shrink-0 text-fg-muted/50">{g.sessions.length}</span>
                </button>
              )}
              {!isCollapsed && g.sessions.map((s) => renderRow(s, grouped))}
            </React.Fragment>
          );
        })}
      </nav>

      {selected.size > 0 && (
        <div
          id="session-multibar"
          className="mx-2 mb-2 flex shrink-0 items-center gap-2 rounded-lg border border-mint/30 bg-bg2 px-2.5 py-1.5 text-[12px] shadow-lg shadow-black/20"
        >
          <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-mint" />
          <span className="min-w-0 flex-1 truncate text-fg">
            {t("sessionsSelected", { count: selected.size })}
          </span>
          <button
            id="delete-selected-button"
            onClick={() => onDeleteMany([...selected])}
            className="shrink-0 rounded-md bg-danger/10 px-2 py-1 font-medium text-danger transition-colors hover:bg-danger/20"
          >
            {t("deleteSelected")}
          </button>
          <button
            aria-label={t("clearSelection")}
            onClick={() => setSelected(new Set())}
            className="grid h-6 w-6 shrink-0 place-items-center rounded-md text-fg-muted transition-colors hover:bg-bg0/60 hover:text-fg"
          >
            ×
          </button>
        </div>
      )}

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

      {ctxMenu && (
        <>
          <div
            className="fixed inset-0 z-40"
            onClick={() => setCtxMenu(null)}
            onContextMenu={(e) => {
              e.preventDefault();
              setCtxMenu(null);
            }}
          />
          <div
            id="session-context-menu"
            className="fixed z-50 min-w-44 rounded-md border border-line bg-bg1 py-1 shadow-xl shadow-black/50"
            style={{
              left: Math.min(ctxMenu.x, window.innerWidth - 190),
              top: Math.min(ctxMenu.y, window.innerHeight - 220),
            }}
          >
            {(() => {
              const close = () => setCtxMenu(null);
              const item = (key: string, label: string, onPick: () => void, danger = false) => (
                <button
                  key={key}
                  data-ctx-item={key}
                  onClick={() => {
                    close();
                    onPick();
                  }}
                  className={`block w-full px-3 py-1.5 text-left font-mono text-xs transition-colors ${
                    danger
                      ? "text-fg-muted hover:bg-danger/10 hover:text-danger"
                      : "text-fg-muted hover:bg-bg2 hover:text-fg"
                  }`}
                >
                  {label}
                </button>
              );

              if (ctxMenu.target.kind === "group") {
                const key = ctxMenu.target.key;
                const ids = groups.find((g) => g.key === key)?.sessions.map((s) => s.id) ?? [];
                return [
                  item("select-group", t("selectGroup"), () =>
                    setSelected((prev) => new Set([...prev, ...ids])),
                  ),
                  item("rename-group", t("renameGroup"), () =>
                    setGroupModal({ ids, initial: key }),
                  ),
                  item("ungroup", t("ungroup"), () => onSetGroup(ids, null)),
                  item("delete-group", t("deleteGroup"), () => onDeleteMany(ids), true),
                ];
              }

              const id = ctxMenu.target.id;
              const inSelection = selected.has(id);
              // Moving acts on the whole selection when the row is part of
              // one — that is what makes multi-select worth discovering.
              const moveIds = inSelection && selected.size > 1 ? [...selected] : [id];
              const session = sessions.find((x) => x.id === id);

              if (ctxMenu.view === "move") {
                return [
                  ...groupNames(sessions).map((name) =>
                    item(`move-to:${name}`, name, () => onSetGroup(moveIds, name)),
                  ),
                  item("new-group", t("newGroup"), () =>
                    setGroupModal({ ids: moveIds, initial: "" }),
                  ),
                  ...(session?.group != null
                    ? [item("remove-from-group", t("removeFromGroup"), () => onSetGroup(moveIds, null))]
                    : []),
                ];
              }

              return [
                item(
                  "toggle-select",
                  inSelection ? t("sessionUnselect") : t("sessionSelect"),
                  () => toggleSelect(id),
                ),
                <button
                  key="move"
                  data-ctx-item="move"
                  onClick={() => setCtxMenu({ ...ctxMenu, view: "move" })}
                  className="flex w-full items-center px-3 py-1.5 text-left font-mono text-xs text-fg-muted transition-colors hover:bg-bg2 hover:text-fg"
                >
                  <span className="min-w-0 flex-1 truncate">
                    {t("moveToGroup")}
                    {moveIds.length > 1 ? ` (${moveIds.length})` : ""}
                  </span>
                  <span className="shrink-0 text-fg-muted/60">›</span>
                </button>,
                ...(selected.size > 1 && inSelection
                  ? [
                      item(
                        "delete-selected",
                        `${t("deleteSelected")} (${selected.size})`,
                        () => onDeleteMany([...selected]),
                        true,
                      ),
                    ]
                  : []),
                item("rename", t("kbRenameSession"), () => onRenameStart(id)),
                item("settings", t("sessionSettings"), () => onOpenSettings(id)),
                item("delete", t("deleteSession"), () => onDelete(id), true),
              ];
            })()}
          </div>
        </>
      )}

      {groupModal && (
        <div
          className="fixed inset-0 z-50 grid place-items-center bg-black/40"
          onClick={() => setGroupModal(null)}
        >
          <form
            id="group-name-modal"
            className="w-72 rounded-xl border border-line bg-bg1 p-4 shadow-2xl shadow-black/50"
            onClick={(e) => e.stopPropagation()}
            onSubmit={(e) => {
              e.preventDefault();
              const name = new FormData(e.currentTarget).get("group")?.toString().trim();
              if (name) onSetGroup(groupModal.ids, name);
              setGroupModal(null);
            }}
          >
            <label className="mb-2 block text-xs font-medium text-fg-muted" htmlFor="group-name-input">
              {t("groupName")}
            </label>
            <input
              id="group-name-input"
              name="group"
              defaultValue={groupModal.initial}
              autoFocus
              maxLength={100}
              autoComplete="off"
              onKeyDown={(e) => {
                if (e.key === "Escape") {
                  e.preventDefault();
                  e.stopPropagation();
                  setGroupModal(null);
                }
              }}
              className="w-full rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-sm text-fg outline-none focus:border-mint/60"
            />
            <div className="mt-3 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setGroupModal(null)}
                className="rounded-md px-2.5 py-1.5 text-fg-muted transition-colors hover:text-fg"
              >
                {t("cancel")}
              </button>
              <button
                id="group-name-confirm"
                type="submit"
                className="rounded-md bg-mint/15 px-2.5 py-1.5 font-medium text-mint transition-colors hover:bg-mint/25"
              >
                {t("save")}
              </button>
            </div>
          </form>
        </div>
      )}
    </aside>
  );

  function renderRow(s: Session, grouped: boolean) {
    const active = s.id === activeId;
    const isSelected = selected.has(s.id);
    return (
            <div
              key={s.id}
              data-session-row={s.id}
              data-selected={isSelected || undefined}
              onClick={(e) => rowClick(e, s.id)}
              onContextMenu={(e) => {
                e.preventDefault();
                setCtxMenu({ x: e.clientX, y: e.clientY, target: { kind: "session", id: s.id } });
              }}
              className={`group relative mb-0.5 flex cursor-pointer items-center gap-2 rounded-lg py-2 pr-2.5 pl-1 transition-colors pointer-coarse:min-h-11 ${
                grouped ? "ml-2" : ""
              } ${
                isSelected
                  ? "bg-mint/10 text-fg ring-1 ring-inset ring-mint/50"
                  : active
                    ? "bg-bg2 text-fg"
                    : "text-fg-muted hover:bg-bg2/60 hover:text-fg"
              } ${drag?.id === s.id ? "opacity-50" : ""}`}
            >
              {dropBeforeId === s.id && (
                <span className="pointer-events-none absolute inset-x-1 -top-[2px] h-0.5 rounded-full bg-mint" />
              )}
              {dropBeforeId === null && drag?.id !== s.id && s.id === lastVisibleId && (
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
                    data-rename-session={s.id}
                    name={s.name}
                    label={t("kbRenameSession")}
                    // Occupy EXACTLY the box the name div occupied: no
                    // border (the shared ring paints without layout), and
                    // the horizontal padding is cancelled by an equal
                    // negative margin. h-5/leading-5 pins the line box to
                    // the div's 20px; `block` avoids inline-block baseline
                    // descender space growing the row.
                    className="-mx-1 block h-5 w-[calc(100%+0.5rem)] px-1 font-mono text-sm leading-5"
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
  }
}
