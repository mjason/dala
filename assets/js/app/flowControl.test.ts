import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createAckCounter } from "./flowControl";

describe("createAckCounter", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("flushes when the byte threshold is reached", () => {
    const sent: [number, boolean][] = [];
    const counter = createAckCounter((bytes, alt) => sent.push([bytes, alt]), 100, 300);
    counter.consumed(60, false);
    expect(sent).toEqual([]);
    counter.consumed(60, false);
    expect(sent).toEqual([[120, false]]);
    // counter resets after flush
    counter.consumed(10, false);
    expect(sent).toHaveLength(1);
  });

  it("flushes small tails on the idle timer", () => {
    const sent: [number, boolean][] = [];
    const counter = createAckCounter((bytes, alt) => sent.push([bytes, alt]), 100, 300);
    counter.consumed(10, true);
    expect(sent).toEqual([]);
    vi.advanceTimersByTime(299);
    expect(sent).toEqual([]);
    vi.advanceTimersByTime(2);
    expect(sent).toEqual([[10, true]]);
  });

  it("reports the LATEST alt-screen flag", () => {
    const sent: [number, boolean][] = [];
    const counter = createAckCounter((bytes, alt) => sent.push([bytes, alt]), 100, 300);
    counter.consumed(60, false);
    counter.consumed(60, true);
    expect(sent).toEqual([[120, true]]);
  });

  it("never sends zero-byte acks and dispose cancels the timer", () => {
    const sent: [number, boolean][] = [];
    const counter = createAckCounter((bytes, alt) => sent.push([bytes, alt]), 100, 300);
    counter.consumed(5, false);
    counter.dispose();
    vi.advanceTimersByTime(1000);
    expect(sent).toEqual([]);
  });

  it("drops pending and late acknowledgements from an older connection epoch", () => {
    const sent: [number, boolean][] = [];
    const counter = createAckCounter((bytes, alt) => sent.push([bytes, alt]), 100, 300);
    const staleEpoch = counter.epoch();

    counter.consumed(60, false, staleEpoch);
    counter.reset();
    vi.advanceTimersByTime(1_000);
    counter.consumed(100, false, staleEpoch);

    expect(sent).toEqual([]);

    counter.consumed(100, true, counter.epoch());
    expect(sent).toEqual([[100, true]]);
  });
});
