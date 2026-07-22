import type { IDisposable, Terminal } from "@xterm/xterm";

type Params = (number | number[])[];

export type HolderQueryOwnership = IDisposable & {
  setEnabled(enabled: boolean): void;
};

export type HolderQueryCapabilities = {
  holder_query_owner?: boolean;
  holder_query_owner_supported?: boolean;
};

export type HolderQueryNegotiator = {
  joined(capabilities: HolderQueryCapabilities): void;
  updated(capabilities: HolderQueryCapabilities): void;
  disconnected(): void;
};

export type TerminalWriteBarrier = {
  beginWrite(): () => void;
  afterPendingWrites(callback: () => void): void;
  dispose(): void;
};

/**
 * Captures xterm's asynchronous write queue at a protocol boundary. A waiter
 * observes only writes issued before it was registered, so output arriving
 * after the boundary cannot starve an ownership transition.
 */
export function createTerminalWriteBarrier(): TerminalWriteBarrier {
  let issued = 0;
  let completed = 0;
  let disposed = false;
  const finishedOutOfOrder = new Set<number>();
  let waiters: { position: number; callback: () => void }[] = [];

  const releaseWaiters = () => {
    const ready: (() => void)[] = [];
    while (waiters[0]?.position <= completed) {
      ready.push(waiters.shift()!.callback);
    }
    for (const callback of ready) callback();
  };

  return {
    beginWrite() {
      if (disposed) return () => {};
      const position = ++issued;
      let finished = false;

      return () => {
        if (disposed || finished) return;
        finished = true;
        finishedOutOfOrder.add(position);
        while (finishedOutOfOrder.delete(completed + 1)) completed += 1;
        releaseWaiters();
      };
    },
    afterPendingWrites(callback) {
      if (disposed) return;
      const position = issued;
      if (position <= completed) callback();
      else waiters.push({ position, callback });
    },
    dispose() {
      disposed = true;
      finishedOutOfOrder.clear();
      waiters = [];
    },
  };
}

// alacritty's VTE handlers use the first value of the first parameter and
// ignore any remaining values. Match that behavior exactly or malformed-but-
// accepted queries could still receive a second reply from xterm.
const firstMainParam = (params: Params) => {
  const first = params[0];
  if (Array.isArray(first)) return first[0] ?? 0;
  return first ?? 0;
};

const firstParamIs = (params: Params, expected: number) =>
  firstMainParam(params) === expected;

/**
 * The holder's alacritty emulator sees PTY output before the browser and
 * answers state queries from the authoritative grid. Consume the overlapping
 * xterm handlers so one shell query never receives two replies.
 */
export function installHolderQueryOwnership(
  term: Pick<Terminal, "parser">,
): HolderQueryOwnership {
  let enabled = false;
  const handlers = [
    term.parser.registerCsiHandler(
      { final: "c" },
      (params) => enabled && firstParamIs(params, 0),
    ),
    term.parser.registerCsiHandler({ prefix: ">", final: "c" }, (params) =>
      enabled && firstParamIs(params, 0),
    ),
    term.parser.registerCsiHandler(
      { final: "n" },
      (params) => enabled && (firstParamIs(params, 5) || firstParamIs(params, 6)),
    ),
    term.parser.registerCsiHandler(
      { intermediates: "$", final: "p" },
      () => enabled,
    ),
    term.parser.registerCsiHandler(
      { prefix: "?", intermediates: "$", final: "p" },
      () => enabled,
    ),
    term.parser.registerCsiHandler(
      { final: "t" },
      (params) => enabled && firstParamIs(params, 18),
    ),
  ];

  return {
    setEnabled(nextEnabled) {
      enabled = nextEnabled;
    },
    dispose() {
      for (const handler of handlers) handler.dispose();
    },
  };
}

/**
 * Orders the browser/server handshake. Xterm remains authoritative until the
 * holder confirms that all output before the ownership transition is sent;
 * the protocol-7 ACK arrives through `updated`.
 */
export function createHolderQueryNegotiator(
  ownership: Pick<HolderQueryOwnership, "setEnabled">,
  ready: () => void,
  afterPendingWrites: (callback: () => void) => void = (callback) => callback(),
): HolderQueryNegotiator {
  return {
    joined(capabilities) {
      const supported = capabilities.holder_query_owner_supported === true;
      afterPendingWrites(() => {
        ownership.setEnabled(false);
        if (supported) ready();
      });
    },
    updated(capabilities) {
      const enabled =
        capabilities.holder_query_owner_supported === true &&
        capabilities.holder_query_owner === true;
      afterPendingWrites(() => ownership.setEnabled(enabled));
    },
    disconnected() {
      afterPendingWrites(() => ownership.setEnabled(false));
    },
  };
}
