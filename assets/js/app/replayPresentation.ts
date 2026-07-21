/**
 * Decide whether a replay may keep the last rendered frame visible.
 *
 * A replay always resets xterm's emulator state; this decision only controls
 * the user-facing cover. Keeping a warm frame avoids a black flash while a
 * screen-only catch-up is travelling through the channel and xterm parser.
 */
export type ReplayTrigger = "initial" | "catch-up" | "flow" | "reset";
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
  return trigger === "catch-up" || trigger === "flow" ? "preserve" : "cover";
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
