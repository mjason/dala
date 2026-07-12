import { describe, expect, it } from "vitest";
import { createStreamGate } from "./streamGate";

describe("createStreamGate", () => {
  it("resets the terminal only on the first replay batch of a join", () => {
    const gate = createStreamGate();

    expect(gate.replayBatch(3, false).reset).toBe(true);
    expect(gate.replayBatch(7, true).reset).toBe(false);
  });

  it("resets again after a rejoin", () => {
    const gate = createStreamGate();
    gate.replayBatch(5, true);
    gate.replayParsed();

    gate.joined();
    expect(gate.replayBatch(9, true).reset).toBe(true);
  });

  it("marks only the final batch for guard release", () => {
    const gate = createStreamGate();

    expect(gate.replayBatch(3, false).release).toBe(false);
    expect(gate.replayBatch(7, true).release).toBe(true);
  });

  it("blocks input while replayed bytes are parsing (query auto-responses)", () => {
    const gate = createStreamGate();
    expect(gate.acceptInput()).toBe(true);

    gate.replayBatch(5, true);
    expect(gate.acceptInput()).toBe(false);

    gate.replayParsed();
    expect(gate.acceptInput()).toBe(true);
  });

  it("blocks input again during a reconnect replay", () => {
    const gate = createStreamGate();
    gate.replayBatch(5, true);
    gate.replayParsed();

    gate.joined();
    gate.replayBatch(9, false);
    expect(gate.acceptInput()).toBe(false);
    gate.replayBatch(12, true);
    gate.replayParsed();
    expect(gate.acceptInput()).toBe(true);
  });

  it("drops live output already covered by the replay snapshot", () => {
    const gate = createStreamGate();
    gate.replayBatch(10, true);

    expect(gate.acceptOutput(9)).toBe(false);
    expect(gate.acceptOutput(10)).toBe(false);
    expect(gate.acceptOutput(11)).toBe(true);
    // duplicates of already-accepted output are dropped too
    expect(gate.acceptOutput(11)).toBe(false);
    expect(gate.acceptOutput(12)).toBe(true);
  });

  it("accepts everything for an empty session (replay seq -1)", () => {
    const gate = createStreamGate();
    gate.replayBatch(-1, true);
    gate.replayParsed();

    expect(gate.acceptOutput(0)).toBe(true);
    expect(gate.acceptInput()).toBe(true);
  });
});

describe("flow-control skip repaint", () => {
  it("mid-session flow replay resets, rebaselines seq and guards input", () => {
    const gate = createStreamGate();
    gate.joined();
    expect(gate.replayBatch(10, true)).toEqual({ reset: true, release: true });
    gate.replayParsed();
    expect(gate.acceptOutput(11)).toBe(true);
    expect(gate.acceptOutput(12)).toBe(true);

    // Link fell behind: server skipped seqs 13..99 and sends a repaint.
    // The client treats it as a fresh join so the screen resets.
    gate.joined();
    const flow = gate.replayBatch(100, true);
    expect(flow.reset).toBe(true);
    expect(flow.release).toBe(true);
    // auto-responses to replayed escape sequences must not reach the PTY
    expect(gate.acceptInput()).toBe(false);
    gate.replayParsed();
    expect(gate.acceptInput()).toBe(true);

    // pre-skip stragglers are dropped, post-repaint output flows
    expect(gate.acceptOutput(99)).toBe(false);
    expect(gate.acceptOutput(101)).toBe(true);
  });
});
