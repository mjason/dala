import { describe, expect, it, vi } from "vitest";
import type { Terminal } from "@xterm/xterm";
import {
  createHolderQueryNegotiator,
  createTerminalWriteBarrier,
  installHolderQueryOwnership,
} from "./terminalQueryOwner";

type Params = (number | number[])[];
type Handler = (params: Params) => boolean | Promise<boolean>;

function fakeTerminal() {
  const handlers = new Map<string, Handler>();
  const disposals: ReturnType<typeof vi.fn>[] = [];
  const registerCsiHandler = vi.fn(
    (id: { prefix?: string; intermediates?: string; final: string }, handler: Handler) => {
      handlers.set(`${id.prefix ?? ""}|${id.intermediates ?? ""}|${id.final}`, handler);
      const dispose = vi.fn();
      disposals.push(dispose);
      return { dispose };
    },
  );
  const term = { parser: { registerCsiHandler } } as unknown as Pick<Terminal, "parser">;
  return { term, handlers, disposals, registerCsiHandler };
}

function result(handler: Handler | undefined, params: Params) {
  if (!handler) throw new Error("expected CSI handler to be registered");
  return handler(params);
}

describe("installHolderQueryOwnership", () => {
  it("claims only terminal queries that the holder answers from authoritative state", () => {
    const { term, handlers } = fakeTerminal();

    const ownership = installHolderQueryOwnership(term);
    ownership.setEnabled(true);

    expect(result(handlers.get("||c"), [0])).toBe(true);
    expect(result(handlers.get(">||c"), [0])).toBe(true);
    expect(result(handlers.get("||n"), [5])).toBe(true);
    expect(result(handlers.get("||n"), [6])).toBe(true);
    expect(result(handlers.get("|$|p"), [4])).toBe(true);
    expect(result(handlers.get("?|$|p"), [2026])).toBe(true);
    expect(result(handlers.get("||t"), [18])).toBe(true);
  });

  it("matches alacritty when extra main or subparameters follow the query", () => {
    const { term, handlers } = fakeTerminal();

    const ownership = installHolderQueryOwnership(term);
    ownership.setEnabled(true);

    expect(result(handlers.get("||c"), [0, 1])).toBe(true);
    expect(result(handlers.get(">||c"), [[0, 2], 1])).toBe(true);
    expect(result(handlers.get("||n"), [6, 1])).toBe(true);
    expect(result(handlers.get("|$|p"), [])).toBe(true);
    expect(result(handlers.get("?|$|p"), [[2026, 1], 9])).toBe(true);
    expect(result(handlers.get("||t"), [[18, 1], 9])).toBe(true);
  });

  it("leaves xterm-only and unsupported reports to xterm", () => {
    const { term, handlers } = fakeTerminal();

    const ownership = installHolderQueryOwnership(term);
    ownership.setEnabled(true);

    expect(result(handlers.get("||n"), [4])).toBe(false);
    expect(result(handlers.get("||n"), [7])).toBe(false);
    expect(result(handlers.get("||t"), [14])).toBe(false);
    expect(result(handlers.get("||t"), [16])).toBe(false);
  });

  it("removes every parser override when the terminal view is disposed", () => {
    const { term, disposals, registerCsiHandler } = fakeTerminal();
    const ownership = installHolderQueryOwnership(term);

    expect(registerCsiHandler).toHaveBeenCalledTimes(6);
    ownership.dispose();

    expect(disposals).toHaveLength(6);
    for (const dispose of disposals) expect(dispose).toHaveBeenCalledOnce();
  });

  it("leaves every query to xterm until a negotiated holder claims ownership", () => {
    const { term, handlers } = fakeTerminal();
    const ownership = installHolderQueryOwnership(term);

    expect(result(handlers.get("||c"), [0])).toBe(false);
    expect(result(handlers.get("||n"), [5])).toBe(false);
    expect(result(handlers.get("?|$|p"), [2026])).toBe(false);

    ownership.setEnabled(true);
    expect(result(handlers.get("||c"), [0])).toBe(true);
    expect(result(handlers.get("||n"), [5])).toBe(true);
    expect(result(handlers.get("?|$|p"), [2026])).toBe(true);

    ownership.setEnabled(false);
    expect(result(handlers.get("||c"), [0])).toBe(false);
  });

  it("keeps xterm authoritative until the holder acknowledges ownership", () => {
    const order: string[] = [];
    const ownership = {
      setEnabled: vi.fn((enabled: boolean) => order.push(`enabled:${enabled}`)),
    };
    const negotiator = createHolderQueryNegotiator(ownership, () => order.push("ready"));

    negotiator.joined({ holder_query_owner_supported: true, holder_query_owner: false });
    expect(order).toEqual(["enabled:false", "ready"]);

    negotiator.updated({ holder_query_owner_supported: true, holder_query_owner: true });
    expect(ownership.setEnabled).toHaveBeenLastCalledWith(true);

    negotiator.updated({ holder_query_owner_supported: true, holder_query_owner: false });
    expect(ownership.setEnabled).toHaveBeenLastCalledWith(false);
  });

  it("applies enable and disable transitions only after prior xterm writes finish", () => {
    const ownership = { setEnabled: vi.fn() };
    const writeBarrier = createTerminalWriteBarrier();
    const negotiator = createHolderQueryNegotiator(
      ownership,
      vi.fn(),
      writeBarrier.afterPendingWrites,
    );

    const finishBeforeEnable = writeBarrier.beginWrite();
    negotiator.updated({ holder_query_owner_supported: true, holder_query_owner: true });
    const finishAfterEnable = writeBarrier.beginWrite();

    expect(ownership.setEnabled).not.toHaveBeenCalled();
    finishBeforeEnable();
    expect(ownership.setEnabled).toHaveBeenLastCalledWith(true);

    // A write queued after the capability frame is not part of that frame's
    // barrier and cannot delay the ownership transition indefinitely.
    finishAfterEnable();
    const finishBeforeDisable = writeBarrier.beginWrite();
    negotiator.updated({ holder_query_owner_supported: true, holder_query_owner: false });

    expect(ownership.setEnabled).toHaveBeenLastCalledWith(true);
    finishBeforeDisable();
    expect(ownership.setEnabled).toHaveBeenLastCalledWith(false);
  });

  it("keeps xterm active for old holders and after disconnect", () => {
    const ready = vi.fn();
    const ownership = { setEnabled: vi.fn() };
    const negotiator = createHolderQueryNegotiator(ownership, ready);

    negotiator.joined({ holder_query_owner_supported: false });
    expect(ownership.setEnabled).toHaveBeenLastCalledWith(false);
    expect(ready).not.toHaveBeenCalled();

    negotiator.disconnected();
    expect(ownership.setEnabled).toHaveBeenLastCalledWith(false);
  });

  it("prevents duplicate xterm replies while preserving xterm-only queries", async () => {
    const canvasContext = vi
      .spyOn(HTMLCanvasElement.prototype, "getContext")
      .mockReturnValue(null);
    const { Terminal: XtermTerminal } = await import("@xterm/xterm");
    const term = new XtermTerminal({ allowProposedApi: true, cols: 80, rows: 24 });
    const replies: string[] = [];
    const replySub = term.onData((data) => replies.push(data));
    const ownership = installHolderQueryOwnership(term);
    ownership.setEnabled(true);
    const write = (data: string) =>
      new Promise<void>((resolve) => {
        term.write(data, resolve);
      });

    try {
      await write(
        "\x1b[c\x1b[>0;1c\x1b[5n\x1b[6;1n\x1b[4;9$p\x1b[?2026:1;9$p\x1b[18;1t",
      );
      expect(replies).toEqual([]);

      await write("\x1b[?6n");
      expect(replies).toEqual(["\x1b[?1;1R"]);
    } finally {
      ownership.dispose();
      replySub.dispose();
      term.dispose();
      canvasContext.mockRestore();
    }
  });
});
