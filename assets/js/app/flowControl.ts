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
  consumed(bytes: number, alt: boolean): void;
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

  const flush = () => {
    window.clearTimeout(timer);
    timer = undefined;
    if (pending === 0) return;
    const bytes = pending;
    pending = 0;
    send(bytes, alt);
  };

  return {
    consumed(bytes, altNow) {
      if (bytes <= 0) return;
      pending += bytes;
      alt = altNow;
      if (pending >= threshold) {
        flush();
      } else if (timer === undefined) {
        timer = window.setTimeout(flush, idleMs);
      }
    },
    dispose() {
      window.clearTimeout(timer);
      timer = undefined;
      pending = 0;
    },
  };
}
