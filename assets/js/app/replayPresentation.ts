/**
 * Decide whether a replay may keep the last rendered frame visible.
 *
 * A replay always resets xterm's emulator state; this decision only controls
 * the user-facing cover. Keeping a warm frame avoids a black flash while a
 * screen-only catch-up is travelling through the channel and xterm parser.
 */
export type ReplayTrigger = "initial" | "catch-up" | "flow" | "reset" | "history";
export type ReplayPresentation = "cover" | "preserve";
export type ReplayBatchPlan = {
  presentation: ReplayPresentation;
  resetBeforeWrite: boolean;
};

export function replayPresentation(
  trigger: ReplayTrigger,
  hasRenderedFrame: boolean,
): ReplayPresentation {
  if (!hasRenderedFrame) return "cover";
  // "history" is a superset of what is already on screen — the same viewport
  // with scrollback above it — and its batches are buffered into one write
  // (see TerminalView), so there is no partial state to hide. Covering it
  // blacked the terminal out for as long as a 512 KiB snapshot took to fetch
  // and parse, which is what "scrolling up goes black for seconds" was.
  return trigger === "catch-up" || trigger === "flow" || trigger === "history"
    ? "preserve"
    : "cover";
}

/** Cover activation is atomic; only revealing the settled frame may fade. */
export function replayCoverTransition(replaying: boolean): string {
  return replaying
    ? "opacity-100 transition-none"
    : "opacity-0 transition-opacity duration-150";
}

/**
 * Plan the first reset batch without exposing an empty or partial emulator.
 * Holder snapshots normally start with RIS (ESC c), which xterm parses in
 * band with the first payload. That preserves the old canvas until the write
 * task runs. A missing RIS still needs the synchronous API reset, while a
 * multi-batch warm snapshot must stay covered until its final batch parses.
 */
export function replayBatchPlan(
  presentation: ReplayPresentation,
  reset: boolean,
  done: boolean,
  data: Uint8Array | string,
): ReplayBatchPlan {
  if (!reset) return { presentation, resetBeforeWrite: false };

  const startsWithRis =
    typeof data === "string"
      ? data.startsWith("\x1bc")
      : data.byteLength >= 2 && data[0] === 0x1b && data[1] === 0x63;
  const resetBeforeWrite = !startsWithRis;
  const mustCover = presentation === "cover" || !done || resetBeforeWrite;

  return {
    presentation: mustCover ? "cover" : "preserve",
    resetBeforeWrite,
  };
}

/**
 * A timed-out catch-up is represented by an empty, non-reset replay. It has no
 * authoritative snapshot, so keep the current pixels but discard the hidden
 * byte buffer once the replay gate is released; otherwise the next reveal
 * would replay stale bytes a second time.
 */
export function shouldDiscardHiddenOutput(
  trigger: ReplayTrigger,
  reset: boolean,
  emptyPayload: boolean,
): boolean {
  return trigger === "catch-up" && !reset && emptyPayload;
}

/**
 * Concatenate the held history batches with the final one. Empty payloads
 * (the holder-unavailable sentinel) contribute nothing.
 */
export function joinHistoryBatches(
  batches: readonly Uint8Array[],
  last: Uint8Array | string,
): Uint8Array | string {
  const tail = typeof last === "string" ? null : last;
  const parts = tail && tail.byteLength > 0 ? [...batches, tail] : [...batches];
  if (parts.length === 0) return typeof last === "string" ? last : new Uint8Array(0);
  if (parts.length === 1) return parts[0];

  const total = parts.reduce((sum, part) => sum + part.byteLength, 0);
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.byteLength;
  }
  return joined;
}
