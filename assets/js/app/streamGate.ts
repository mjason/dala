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
   * A replay batch arrived. `reset` — clear the terminal before writing
   * this batch; `release` — this is the final batch: once its bytes are
   * parsed (xterm write callback), call `replayParsed()`.
   */
  replayBatch(seq: number, done: boolean): { reset: boolean; release: boolean };
  /** The final replay batch finished parsing; input may flow again. */
  replayParsed(): void;
  /** Should this live output chunk be written? (false = duplicate) */
  acceptOutput(seq: number): boolean;
  /** Should terminal-emitted data be forwarded to the PTY as input? */
  acceptInput(): boolean;
};

export function createStreamGate(): StreamGate {
  let awaitingReplay = true;
  let replaying = false;
  let lastSeq = -1;

  return {
    joined() {
      awaitingReplay = true;
    },

    replayBatch(seq, done) {
      const reset = awaitingReplay;
      if (awaitingReplay) {
        awaitingReplay = false;
        replaying = true;
      }
      if (seq > lastSeq) lastSeq = seq;
      return { reset, release: done };
    },

    replayParsed() {
      replaying = false;
    },

    acceptOutput(seq) {
      if (seq <= lastSeq) return false;
      lastSeq = seq;
      return true;
    },

    acceptInput() {
      return !replaying;
    },
  };
}
