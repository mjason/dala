export type TerminalWarmEnvironment = {
  coarsePointer: boolean;
  deviceMemory?: number;
  devicePixelRatio?: number;
  viewportWidth?: number;
  viewportHeight?: number;
};

const MIB = 1024 * 1024;
const FULL_CANVAS_LAYERS = 2;

/** Keep a common workspace warm without letting high-DPR canvases exhaust GPU memory. */
export function terminalWarmLimit(env: TerminalWarmEnvironment): number {
  const lowMemory = env.deviceMemory !== undefined && env.deviceMemory <= 4;
  const baseLimit = env.coarsePointer ? 3 : lowMemory ? 6 : 10;
  const dpr = Math.max(env.devicePixelRatio ?? 1, 1);
  const width = env.viewportWidth ?? 0;
  const height = env.viewportHeight ?? 0;
  if (width <= 0 || height <= 0) return baseLimit;

  // xterm keeps a full-size WebGL canvas plus a full-size overlay. This is a
  // conservative RGBA backing-store estimate; textures and driver allocations
  // sit on top, so the budget intentionally stays below total device memory.
  const bytesPerTerminal = width * height * dpr * dpr * 4 * FULL_CANVAS_LAYERS;
  const canvasBudget = (lowMemory ? 96 : 160) * MIB;
  const pixelLimit = Math.max(2, Math.floor(canvasBudget / bytesPerTerminal));
  return Math.min(baseLimit, pixelLimit);
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
