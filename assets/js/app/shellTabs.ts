import type { Session } from "./Sidebar";

/**
 * Attached shells are a session's extra terminals, shown as tabs next to its
 * main shell (the tmux model). The sidebar stays a list of sessions: a child
 * never appears there, only a count badge on its parent.
 *
 * The rest of the app keeps treating "the session you are looking at" as one
 * id — a tab switch is just a different active session — so everything hung
 * off that id (terminal pool, composer, git panel, drawer) works unchanged.
 */

/** Sessions that own a sidebar row: the ones with no parent. */
export function rootSessions(sessions: Session[]): Session[] {
  return sessions.filter((s) => !s.parentId);
}

/** The sidebar row that owns `id` — itself, or its parent when it is a tab. */
export function rootIdOf(sessions: Session[], id: string | null): string | null {
  if (!id) return null;
  const session = sessions.find((s) => s.id === id);
  if (!session) return id;
  return session.parentId ?? session.id;
}

/**
 * The tab strip for a session: its main shell first, then its attached shells
 * in creation order. Returns [] when the root is unknown, so a caller mid-
 * delete renders nothing rather than a stray tab.
 */
export function tabsFor(sessions: Session[], rootId: string | null): Session[] {
  if (!rootId) return [];
  const root = sessions.find((s) => s.id === rootId && !s.parentId);
  if (!root) return [];

  const attached = sessions
    .filter((s) => s.parentId === rootId)
    .sort((a, b) =>
      a.position === b.position
        ? a.insertedAt.localeCompare(b.insertedAt)
        : a.position - b.position,
    );

  return [root, ...attached];
}

/** How many attached shells a session has (the sidebar badge). */
export function attachedCount(sessions: Session[], rootId: string): number {
  return sessions.reduce((total, s) => (s.parentId === rootId ? total + 1 : total), 0);
}

/**
 * Where to go when the visible tab is closed: its parent if it had one (you
 * were there before opening it), else the most recent session that still
 * exists. Falling back to MRU alone would jump to an unrelated session that
 * merely happened to be visited more recently than the parent.
 */
export function tabAfterClose(
  sessions: Session[],
  closedId: string,
  mruFallback: string | undefined,
): string | undefined {
  const closed = sessions.find((s) => s.id === closedId);
  const parentId = closed?.parentId;
  if (parentId && sessions.some((s) => s.id === parentId && s.id !== closedId)) return parentId;
  return mruFallback;
}

/**
 * The 1-based tab index a desktop-client menu action asks for, or null.
 *
 * These arrive as `dala:menu` events (⌘1..9 / Ctrl+1..9 accelerators in the
 * Electron menu) rather than keydowns: inside a browser tab those combos are
 * the browser's own and never reach the page.
 */
export function tabActionIndex(action: string): number | null {
  const match = /^switch-tab-([1-9])$/.exec(action);
  return match ? Number(match[1]) : null;
}
