/**
 * Automatic sidebar grouping: sessions sharing a working directory form one
 * collapsible group (zero management — the cwd IS the project identity).
 * Groups appear at their first session's position, so manual drag order
 * still decides both group order and in-group order. A directory with a
 * single session renders as a plain row (a one-row group is noise).
 */

type HasCwd = { id: string; cwd: string };

export type SessionGroup<S extends HasCwd> = {
  /** Stable identity for collapse persistence: the cwd itself. */
  key: string;
  /** Short display label: the directory's basename. */
  label: string;
  sessions: S[];
};

export function groupSessions<S extends HasCwd>(sessions: readonly S[]): SessionGroup<S>[] {
  const groups: SessionGroup<S>[] = [];
  const byKey = new Map<string, SessionGroup<S>>();

  for (const session of sessions) {
    const key = session.cwd;
    const existing = byKey.get(key);
    if (existing) {
      existing.sessions.push(session);
    } else {
      const group = { key, label: basename(key), sessions: [session] };
      byKey.set(key, group);
      groups.push(group);
    }
  }

  return groups;
}

function basename(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  if (trimmed === "") return "/";
  const slash = trimmed.lastIndexOf("/");
  return slash >= 0 ? trimmed.slice(slash + 1) : trimmed;
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
