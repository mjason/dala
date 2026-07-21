/**
 * Pure state machine for the terminal channel stream.
 *
 * Encodes the three invariants that keep a session correct across
 * refreshes and reconnects:
 *
 * 1. After every (re)join the first replay batch must repaint from a clean
 *    slate (terminal reset).
 * 2. Live `output` chunks overlapping the replay snapshot are deduplicated
 *    by `seq`.
 * 3. While replayed bytes are being parsed, anything the terminal emits is
 *    an auto-response to historical escape sequences (vim's device probes,
 *    color queries, …) and must NOT be forwarded to the PTY — the shell
 *    would receive it as typed input.
 */
export type StreamGate = {
  /** The channel (re)joined: the next replay batch starts a fresh repaint. */
  joined(): void;
  /**
   * A warm catch-up request is in flight. Hold live output until the server
   * sends either its authoritative reset replay or the empty timeout
   * fallback. Unlike `joined`, the first non-reset batch must not clear the
   * already-rendered frame.
   */
  waitForReplay(): void;
  /**
   * A replay batch arrived. `reset` — clear the terminal before writing
   * this batch; `release` — this is the final batch: once its bytes are
   * parsed (xterm write callback), call `replayParsed()`.
   */
  replayBatch(
    seq: number,
    done: boolean,
    wireReset?: boolean,
  ): { reset: boolean; release: boolean; generation: number; firstBatch: boolean };
  /**
   * The final replay batch finished parsing. Returns true only when this is
   * still the current replay generation; callers must guard every settlement
   * side effect with the result.
   */
  replayParsed(generation: number): boolean;
  /** Should this live output chunk be written? (false = duplicate) */
  acceptOutput(seq: number): boolean;
  /** True while a requested replay has not delivered its first batch. */
  isReplayPending(): boolean;
  /** Should terminal-emitted data be forwarded to the PTY as input? */
  acceptInput(): boolean;
};

export function createStreamGate(): StreamGate {
  let awaitingReplay = true;
  // A join/flow replay always clears xterm on its first batch. A warm
  // catch-up waits for the same barrier but preserves the frame when the
  // timeout fallback is an empty non-reset replay.
  let resetFirstReplay = true;
  let replaying = false;
  let lastSeq = -1;
  let generation = 0;
  // Phoenix delivers a multi-batch replay as separate message events. A new
  // user request can start between those events, so retain the old token until
  // its wire-level `done` edge instead of assigning its tail to the new wait.
  let wireReplayGeneration: number | null = null;

  return {
    joined() {
      if (!awaitingReplay) generation++;
      // A channel join is a hard transport boundary. If the previous socket
      // disappeared mid-replay its final batch can never arrive, so the next
      // connection's snapshot must start a new wire replay. Warm waits do not
      // clear this token because old batches can still be queued on the same
      // connection and need to retain their superseded generation.
      wireReplayGeneration = null;
      awaitingReplay = true;
      resetFirstReplay = true;
      replaying = true;
    },

    waitForReplay() {
      // A request made while a join/reconnect barrier is already pending is
      // coalesced server-side into that snapshot. It must not downgrade the
      // required clean reset into a warm timeout-style replay.
      if (!awaitingReplay) {
        generation++;
        resetFirstReplay = false;
      }
      awaitingReplay = true;
      replaying = true;
    },

    replayBatch(seq, done, wireReset = false) {
      const firstBatch = wireReplayGeneration == null;
      if (firstBatch) {
        // A defensive path for an unsolicited non-reset replay (for example a
        // flow timeout fallback). It is still a distinct parse generation and
        // must invalidate a callback left behind by the previous replay.
        if (!awaitingReplay) generation++;
        wireReplayGeneration = generation;
      }

      const batchGeneration = wireReplayGeneration ?? generation;
      const reset = firstBatch && awaitingReplay && (resetFirstReplay || wireReset);

      if (firstBatch) {
        if (awaitingReplay) {
          awaitingReplay = false;
          // The replay defines the new dedup baseline outright: after a server
          // restart its seq counter may restart lower, and keeping the old
          // (higher) watermark would silently drop all live output.
          // An empty, non-reset catch-up timeout is different: it carries no
          // authoritative watermark, so retain the settled frame's baseline.
          if (reset) lastSeq = seq;
        } else if (seq > lastSeq) {
          lastSeq = seq;
        }
        replaying = true;
      } else if (seq > lastSeq) {
        lastSeq = seq;
      }

      if (done) wireReplayGeneration = null;
      return { reset, release: done, generation: batchGeneration, firstBatch };
    },

    replayParsed(parsedGeneration) {
      if (parsedGeneration !== generation) return false;
      replaying = false;
      return true;
    },

    acceptOutput(seq) {
      // A catch-up barrier covers all output currently in flight. Do not
      // render a transient delta into the old emulator before its snapshot;
      // the caller acknowledges the bytes so the server ledger can converge.
      if (awaitingReplay) return false;
      if (seq <= lastSeq) return false;
      lastSeq = seq;
      return true;
    },

    isReplayPending() {
      return awaitingReplay;
    },

    acceptInput() {
      return !replaying;
    },
  };
}
