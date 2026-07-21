/**
 * Client half of the terminal output flow control: counts bytes the terminal
 * has actually PARSED (xterm write callbacks) and acknowledges them to the
 * channel in batches. The server tracks sent-minus-acked per client; when a
 * slow link lets that backlog grow past a watermark it stops streaming,
 * waits for the acks to drain and sends one repaint snapshot instead — the
 * mosh idea: sync the latest state, don't replay history you can't afford.
 */
export type AckCounter = {
  /** Bytes finished parsing; `alt` = terminal currently on the alt screen. */
  consumed(bytes: number, alt: boolean, epoch?: number): void;
  /** Current connection epoch, captured by asynchronous xterm writes. */
  epoch(): number;
  /** Starts a fresh Channel ledger and discards the prior epoch's tail. */
  reset(): void;
  dispose(): void;
};

export function createAckCounter(
  send: (bytes: number, alt: boolean) => void,
  threshold = 16 * 1024,
  idleMs = 300,
): AckCounter {
  let pending = 0;
  let alt = false;
  let timer: number | undefined;
  let epoch = 0;

  const clear = () => {
    window.clearTimeout(timer);
    timer = undefined;
    pending = 0;
  };

  const flush = () => {
    window.clearTimeout(timer);
    timer = undefined;
    if (pending === 0) return;
    const bytes = pending;
    pending = 0;
    send(bytes, alt);
  };

  return {
    consumed(bytes, altNow, sourceEpoch = epoch) {
      if (bytes <= 0 || sourceEpoch !== epoch) return;
      pending += bytes;
      alt = altNow;
      if (pending >= threshold) {
        flush();
      } else if (timer === undefined) {
        timer = window.setTimeout(flush, idleMs);
      }
    },
    epoch: () => epoch,
    reset() {
      epoch += 1;
      clear();
    },
    dispose() {
      epoch += 1;
      clear();
    },
  };
}
