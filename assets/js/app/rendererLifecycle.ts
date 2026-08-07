/**
 * How many HIDDEN terminals may keep their WebGL renderer alive.
 *
 * Disposing the addon the instant a tab is hidden and rebuilding it on
 * reveal makes the common flip — main shell ↔ the tab running `rails s` —
 * pay a shader compile and glyph-atlas rebuild in BOTH directions, which is
 * the jank you feel on the tab strip. Keeping every pooled terminal's
 * context is the other extreme: browsers cap live WebGL contexts per page
 * (~16) and silently kill the oldest, which arrives as a context-loss storm.
 * So only the most recently hidden terminal stays warm: at most two live
 * contexts, and going back and forth costs nothing.
 */
export const WARM_HIDDEN_RENDERERS = 1;

/**
 * Bounded set of hidden terminals allowed to keep their renderer. Callers
 * hand over the teardown they would otherwise have run immediately; it fires
 * when the entry is pushed out.
 */
export function createWarmRendererPool(limit: number = WARM_HIDDEN_RENDERERS) {
  const entries: { id: string; release: () => void }[] = [];

  const drop = (id: string) => {
    const index = entries.findIndex((entry) => entry.id === id);
    if (index >= 0) entries.splice(index, 1);
  };

  return {
    /**
     * A terminal went hidden. Returns false when it must tear its renderer
     * down right now (the pool is disabled), true when the pool took over
     * and will release it later.
     */
    retain(id: string, release: () => void): boolean {
      if (limit <= 0) return false;
      drop(id);
      entries.unshift({ id, release });
      while (entries.length > limit) entries.pop()?.release();
      return true;
    },
    /** The terminal is visible again, or gone: it owns its renderer now. */
    forget(id: string) {
      drop(id);
    },
    /** Ids currently held warm, most recently hidden first (diagnostics). */
    warm: () => entries.map((entry) => entry.id),
  };
}

/** Run context-loss recovery only for the addon that still owns the renderer. */
export function recoverOwnedWebglContext(
  ownerGeneration: number,
  currentGeneration: number,
  recover: () => void,
): boolean {
  if (ownerGeneration !== currentGeneration) return false;
  recover();
  return true;
}
