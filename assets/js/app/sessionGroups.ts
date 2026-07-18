/**
 * Manual sidebar grouping: a session's user-assigned `group` label decides
 * its cluster (right-click → move to group). Ungrouped sessions render as
 * plain rows in an anonymous pseudo-group. A group appears at its first
 * member's position, so drag order still decides both group order and
 * in-group order — and a named group keeps its header even with one member
 * (the user made it on purpose).
 */

type HasGroup = { id: string; group: string | null };

export type SessionGroup<S extends HasGroup> = {
  /** The group name; null = the ungrouped run of rows between groups. */
  key: string | null;
  sessions: S[];
};

export function groupSessions<S extends HasGroup>(sessions: readonly S[]): SessionGroup<S>[] {
  const groups: SessionGroup<S>[] = [];
  const byKey = new Map<string, SessionGroup<S>>();
  let looseRun: SessionGroup<S> | null = null;

  for (const session of sessions) {
    const key = session.group;
    if (key == null) {
      // Consecutive ungrouped rows share one pseudo-group; a named group in
      // between starts a new run so plain rows never jump past a group.
      if (!looseRun) {
        looseRun = { key: null, sessions: [] };
        groups.push(looseRun);
      }
      looseRun.sessions.push(session);
      continue;
    }
    looseRun = null;
    const existing = byKey.get(key);
    if (existing) {
      existing.sessions.push(session);
    } else {
      const group = { key, sessions: [session] };
      byKey.set(key, group);
      groups.push(group);
    }
  }

  return groups;
}

/** All distinct group names, in sidebar order (for the move-to-group menu). */
export function groupNames(sessions: readonly { group: string | null }[]): string[] {
  const names: string[] = [];
  const seen = new Set<string>();
  for (const s of sessions) {
    if (s.group != null && !seen.has(s.group)) {
      seen.add(s.group);
      names.push(s.group);
    }
  }
  return names;
}

/** Inclusive id range between anchor and target within the visible order
 * (shift-click selection). Falls back to just the target when the anchor is
 * not visible (collapsed away or deleted). */
export function rangeBetween(
  visibleIds: readonly string[],
  anchorId: string,
  targetId: string,
): string[] {
  const a = visibleIds.indexOf(anchorId);
  const b = visibleIds.indexOf(targetId);
  if (a === -1 || b === -1) return targetId ? [targetId] : [];
  const [from, to] = a <= b ? [a, b] : [b, a];
  return visibleIds.slice(from, to + 1);
}
