export type HistoryIntent = "scroll" | "find";

export type LazyHistory = {
  /** Returns true exactly once when a full-history request should be sent. */
  request(intent: HistoryIntent): boolean;
  /** Records an authoritative repaint and returns the intent to resume. */
  finishReplay(historyLoaded: boolean, retrying?: boolean): HistoryIntent | null;
  isLoaded(): boolean;
  isPending(): boolean;
};

/** State shared by wheel, touch and find-driven on-demand history loading. */
export function createLazyHistory(): LazyHistory {
  let loaded = false;
  let pending = false;
  let intent: HistoryIntent | null = null;

  return {
    request(nextIntent) {
      if (loaded || pending) return false;
      pending = true;
      intent = nextIntent;
      return true;
    },
    finishReplay(historyLoaded, retrying = false) {
      // An empty retry fallback only releases the visual/input wait. The
      // original scroll/find request remains owned by the authoritative retry.
      if (retrying) return null;
      loaded = historyLoaded;
      pending = false;
      const resume = intent;
      intent = null;
      return resume;
    },
    isLoaded: () => loaded,
    isPending: () => pending,
  };
}
