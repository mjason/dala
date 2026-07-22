import { useEffect, useMemo, useState } from "react";
import { nextWarmSession, touchTerminalPool } from "../terminalPool";

const storageKey = "dala:terminal-pool";

type Options = {
  activeId: string | null;
  sessionIds: readonly string[];
  connected: boolean;
  limit: number;
};

function sameIds(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((id, index) => id === right[index]);
}

function readWarmOrder(): string[] {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(storageKey) ?? "[]");
    if (!Array.isArray(parsed)) return [];
    return [...new Set(parsed.filter((id): id is string => typeof id === "string"))];
  } catch {
    return [];
  }
}

/** Mount the active terminal immediately, then restore the remaining MRU pool while idle. */
export function useTerminalPool({ activeId, sessionIds, connected, limit }: Options): string[] {
  const [pool, setPool] = useState<string[]>([]);
  const [warmOrder, setWarmOrder] = useState<string[]>(readWarmOrder);

  useEffect(() => {
    if (!activeId) return;
    setPool((previous) => touchTerminalPool(previous, activeId, limit));
    setWarmOrder((previous) => touchTerminalPool(previous, activeId, limit));
  }, [activeId, limit]);

  useEffect(() => {
    // `connected` becomes true before the initial session snapshot resolves.
    // Keep the persisted order intact until that snapshot yields an active row.
    if (!connected || activeId == null) return;
    const alive = new Set(sessionIds);
    const retainAlive = (previous: string[]) => {
      const next = previous.filter((id) => alive.has(id)).slice(0, limit);
      return sameIds(previous, next) ? previous : next;
    };
    setPool(retainAlive);
    setWarmOrder(retainAlive);
  }, [activeId, connected, sessionIds, limit]);

  useEffect(() => {
    try {
      localStorage.setItem(storageKey, JSON.stringify(warmOrder));
    } catch {
      // The mounted pool still works when browser storage is unavailable.
    }
  }, [warmOrder]);

  const preferredIds = useMemo(
    () => [...new Set([...warmOrder, ...sessionIds])],
    [warmOrder, sessionIds],
  );

  useEffect(() => {
    if (
      !connected ||
      activeId == null ||
      pool.length >= limit ||
      !pool.includes(activeId)
    ) {
      return;
    }

    const warm = () => {
      setPool((previous) => {
        const candidate = nextWarmSession(previous, preferredIds, limit);
        return candidate ? [...previous, candidate] : previous;
      });
    };

    if (typeof window.requestIdleCallback === "function") {
      const id = window.requestIdleCallback(warm, { timeout: 1_500 });
      return () => window.cancelIdleCallback?.(id);
    }

    const id = globalThis.setTimeout(warm, 250);
    return () => globalThis.clearTimeout(id);
  }, [activeId, connected, limit, pool, preferredIds]);

  return pool;
}
