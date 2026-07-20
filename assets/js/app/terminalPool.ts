export type TerminalWarmEnvironment = {
  coarsePointer: boolean;
  deviceMemory?: number;
};

/** Keep a whole common desktop workspace warm without exhausting mobile GPUs. */
export function terminalWarmLimit(env: TerminalWarmEnvironment): number {
  if (env.coarsePointer) return 3;
  if (env.deviceMemory !== undefined && env.deviceMemory <= 4) return 6;
  return 10;
}

/** Move an explicitly selected session to the MRU head, evicting only at the cap. */
export function touchTerminalPool(pool: readonly string[], id: string, limit: number): string[] {
  return [id, ...pool.filter((entry) => entry !== id)].slice(0, Math.max(1, limit));
}

/** Find one idle-warm candidate. Background warming never evicts a user-hot session. */
export function nextWarmSession(
  pool: readonly string[],
  preferredIds: readonly string[],
  limit: number,
): string | null {
  if (pool.length >= limit) return null;
  return preferredIds.find((id) => !pool.includes(id)) ?? null;
}
