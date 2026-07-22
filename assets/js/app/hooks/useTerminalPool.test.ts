import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useTerminalPool } from "./useTerminalPool";

describe("useTerminalPool cold start", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("does not warm persisted sessions before the active session is known", async () => {
    localStorage.setItem("dala:terminal-pool", JSON.stringify(["s4", "s2"]));
    const idleCallbacks: IdleRequestCallback[] = [];
    vi.stubGlobal(
      "requestIdleCallback",
      vi.fn((callback: IdleRequestCallback) => {
        idleCallbacks.push(callback);
        return idleCallbacks.length;
      }),
    );
    vi.stubGlobal("cancelIdleCallback", vi.fn());

    const { result, rerender } = renderHook(
      ({ activeId }: { activeId: string | null }) =>
        useTerminalPool({
          activeId,
          sessionIds: ["s1", "s2", "s4"],
          connected: true,
          limit: 5,
        }),
      { initialProps: { activeId: null as string | null } },
    );

    expect(result.current).toEqual([]);
    expect(idleCallbacks).toHaveLength(0);

    rerender({ activeId: "s1" });
    await waitFor(() => expect(result.current).toEqual(["s1"]));
    expect(idleCallbacks).toHaveLength(1);
  });

  it("mounts only the active session after a full-pool reload, then warms stored MRU order", async () => {
    const stored = ["s4", "s2", "s1", "s3", "s5"];
    localStorage.setItem("dala:terminal-pool", JSON.stringify(stored));
    const idleCallbacks: IdleRequestCallback[] = [];
    vi.stubGlobal(
      "requestIdleCallback",
      vi.fn((callback: IdleRequestCallback) => {
        idleCallbacks.push(callback);
        return idleCallbacks.length;
      }),
    );
    vi.stubGlobal("cancelIdleCallback", vi.fn());

    const { result } = renderHook(() =>
      useTerminalPool({
        activeId: "s1",
        sessionIds: ["s1", "s2", "s3", "s4", "s5"],
        connected: true,
        limit: 5,
      }),
    );

    await waitFor(() => expect(result.current).toEqual(["s1"]));
    expect(idleCallbacks).toHaveLength(1);

    act(() => {
      idleCallbacks.shift()?.({ didTimeout: false, timeRemaining: () => 20 });
    });

    await waitFor(() => expect(result.current).toEqual(["s1", "s4"]));
  });
});
