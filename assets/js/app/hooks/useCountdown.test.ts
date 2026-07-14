import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, renderHook } from "@testing-library/react";
import { useCountdown } from "./useCountdown";

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("useCountdown", () => {
  it("starts hidden", () => {
    const { result } = renderHook(() => useCountdown());
    expect(result.current.seconds).toBeNull();
  });

  it("counts down once per second and expires to null", () => {
    const { result } = renderHook(() => useCountdown());
    act(() => result.current.start(5));
    expect(result.current.seconds).toBe(5);

    act(() => vi.advanceTimersByTime(1000));
    expect(result.current.seconds).toBe(4);

    act(() => vi.advanceTimersByTime(3000));
    expect(result.current.seconds).toBe(1);

    act(() => vi.advanceTimersByTime(1000));
    expect(result.current.seconds).toBeNull();
  });

  it("a 5s countdown is gone within 6 seconds of wall time", () => {
    const { result } = renderHook(() => useCountdown());
    act(() => result.current.start(5));
    act(() => vi.advanceTimersByTime(6000));
    expect(result.current.seconds).toBeNull();
  });

  it("clear() hides immediately and stops the ticking", () => {
    const { result } = renderHook(() => useCountdown());
    act(() => result.current.start(5));
    act(() => result.current.clear());
    expect(result.current.seconds).toBeNull();

    act(() => vi.advanceTimersByTime(10_000));
    expect(result.current.seconds).toBeNull();
  });

  it("start() restarts an expired countdown", () => {
    const { result } = renderHook(() => useCountdown());
    act(() => result.current.start(2));
    act(() => vi.advanceTimersByTime(2000));
    expect(result.current.seconds).toBeNull();

    act(() => result.current.start(3));
    expect(result.current.seconds).toBe(3);
    act(() => vi.advanceTimersByTime(1000));
    expect(result.current.seconds).toBe(2);
  });

  it("unmount cleans the interval up", () => {
    const { result, unmount } = renderHook(() => useCountdown());
    act(() => result.current.start(5));
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
});
