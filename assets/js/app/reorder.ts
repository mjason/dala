// Pure logic for the sidebar's drag-to-reorder.
//
// Ordering is a server-persisted float `position` (ties broken by
// insertedAt) so every device sees the same list. A move is expressed as
// "put me before session X" (null = the end); the position math here
// mirrors `Dala.Terminal.Session.Position` for optimistic updates — the
// server's session_updated broadcast then confirms (or corrects) it.

type Ordered = { id: string; position: number; insertedAt: string };

/** Sidebar sort: position, then insertedAt for ties (matches the server). */
export function byPosition(a: Ordered, b: Ordered): number {
  return a.position - b.position || a.insertedAt.localeCompare(b.insertedAt);
}

/**
 * Insertion slot for a pointer at `y`, given the row vertical midpoints in
 * list order. Slots count positions in the list *without* the dragged row:
 * 0 = front, rows-1 = end.
 */
export function insertionIndex(midpoints: number[], dragIndex: number, y: number): number {
  let slot = 0;
  midpoints.forEach((mid, i) => {
    if (i !== dragIndex && y > mid) slot++;
  });
  return slot;
}

/** Session the dragged row should land before (null = move to the end). */
export function beforeIdFor(
  list: readonly { id: string }[],
  dragId: string,
  slot: number,
): string | null {
  const others = list.filter((s) => s.id !== dragId);
  return others[slot]?.id ?? null;
}

/** New float position for `dragId` moving before `beforeId` (null = end). */
export function positionBefore(list: readonly Ordered[], dragId: string, beforeId: string | null): number {
  const others = [...list].sort(byPosition).filter((s) => s.id !== dragId);
  const index = beforeId == null ? -1 : others.findIndex((s) => s.id === beforeId);
  if (index === -1) return (others[others.length - 1]?.position ?? 0) + 1;
  if (index === 0) {
    const first = others[0].position;
    return first > 0 ? first / 2 : first - 1;
  }
  return (others[index - 1].position + others[index].position) / 2;
}

/** Optimistic move: same list with the dragged session's position updated. */
export function applyReorder<T extends Ordered>(
  list: readonly T[],
  dragId: string,
  beforeId: string | null,
): T[] {
  const position = positionBefore(list, dragId, beforeId);
  return list.map((s) => (s.id === dragId ? { ...s, position } : s));
}
