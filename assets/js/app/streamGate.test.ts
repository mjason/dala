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
    const initial = gate.replayBatch(5, true);
    gate.replayParsed(initial.generation);

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

    const replay = gate.replayBatch(5, true);
    gate.parseStarted();
    expect(gate.acceptInput()).toBe(false);

    gate.parseFinished();
    gate.replayParsed(replay.generation);
    expect(gate.acceptInput()).toBe(true);
  });

  it("keeps input flowing while a replay is only in flight", () => {
    const gate = createStreamGate();
    const initial = gate.replayBatch(5, true);
    gate.parseStarted();
    gate.parseFinished();
    gate.replayParsed(initial.generation);

    // Requesting a snapshot (rejoin, tab reveal, flow repaint) produces no
    // emulator output at all until its bytes land — everything typed in that
    // window is the USER, and on a slow link the window is a whole
    // round-trip. Swallowing it there lost real keystrokes.
    gate.joined();
    expect(gate.acceptInput()).toBe(true);
    gate.waitForReplay();
    expect(gate.acceptInput()).toBe(true);
  });

  it("re-blocks input for every batch of a multi-batch replay", () => {
    const gate = createStreamGate();
    gate.joined();

    gate.replayBatch(9, false);
    gate.parseStarted();
    expect(gate.acceptInput()).toBe(false);
    gate.parseFinished();
    expect(gate.acceptInput()).toBe(true);

    const replay = gate.replayBatch(12, true);
    gate.parseStarted();
    expect(gate.acceptInput()).toBe(false);
    gate.parseFinished();
    gate.replayParsed(replay.generation);
    expect(gate.acceptInput()).toBe(true);
  });

  it("stays blocked until the last overlapping parse finishes", () => {
    const gate = createStreamGate();
    gate.parseStarted();
    gate.parseStarted();
    gate.parseFinished();
    expect(gate.acceptInput()).toBe(false);
    gate.parseFinished();
    expect(gate.acceptInput()).toBe(true);
    // Never goes negative on a stray extra callback.
    gate.parseFinished();
    gate.parseStarted();
    expect(gate.acceptInput()).toBe(false);
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

  it("drops and waits for live output while a catch-up replay is pending", () => {
    const gate = createStreamGate();
    const initial = gate.replayBatch(10, true);
    gate.replayParsed(initial.generation);

    gate.waitForReplay();
    expect(gate.isReplayPending()).toBe(true);
    expect(gate.acceptOutput(11)).toBe(false);
    // Output is held back (the snapshot supersedes it) but typing is not.
    expect(gate.acceptInput()).toBe(true);

    // A timeout fallback has no reset bit: release the wait without clearing
    // the settled frame, then resume the stream at the fallback watermark.
    const fallback = gate.replayBatch(0, true, false);
    expect(fallback).toMatchObject({ reset: false, release: true });
    expect(gate.isReplayPending()).toBe(false);
    gate.replayParsed(fallback.generation);
    expect(gate.acceptInput()).toBe(true);
    expect(gate.acceptOutput(10)).toBe(false);
    expect(gate.acceptOutput(11)).toBe(true);
    expect(gate.acceptOutput(11)).toBe(false);
    expect(gate.acceptOutput(12)).toBe(true);
  });

  it("still resets when the catch-up snapshot arrives", () => {
    const gate = createStreamGate();
    const initial = gate.replayBatch(10, true);
    gate.replayParsed(initial.generation);
    gate.waitForReplay();

    // The channel marks an authoritative holder snapshot with reset=true.
    gate.joined();
    expect(gate.replayBatch(20, true, true)).toMatchObject({ reset: true, release: true });
  });

  it("does not let a warm wait downgrade an existing join barrier", () => {
    const gate = createStreamGate();
    const initial = gate.replayBatch(10, true);
    gate.replayParsed(initial.generation);

    gate.joined();
    gate.waitForReplay();

    const replay = gate.replayBatch(20, true, false);
    expect(replay.reset).toBe(true);
    expect(gate.acceptOutput(20)).toBe(false);
  });

  it("rejects a stale final callback after a newer replay starts", () => {
    const gate = createStreamGate();
    const initial = gate.replayBatch(10, true);
    expect(gate.replayParsed(initial.generation)).toBe(true);

    gate.joined();
    const oldReplay = gate.replayBatch(20, true);
    gate.waitForReplay();

    let settlements = 0;
    if (gate.replayParsed(oldReplay.generation)) settlements++;
    expect(settlements).toBe(0);

    gate.joined();
    const currentReplay = gate.replayBatch(30, true, true);
    if (gate.replayParsed(currentReplay.generation)) settlements++;
    expect(settlements).toBe(1);
  });

  it("keeps late batches on the superseded replay generation", () => {
    const gate = createStreamGate();
    const initial = gate.replayBatch(10, true);
    gate.replayParsed(initial.generation);

    gate.joined();
    const oldFirst = gate.replayBatch(20, false);
    expect(oldFirst.firstBatch).toBe(true);
    gate.waitForReplay();
    const oldFinal = gate.replayBatch(20, true);

    expect(oldFinal.generation).toBe(oldFirst.generation);
    expect(oldFinal.firstBatch).toBe(false);
    expect(gate.replayParsed(oldFinal.generation)).toBe(false);

    gate.joined();
    const current = gate.replayBatch(30, true, true);
    expect(current.firstBatch).toBe(true);
    expect(current.generation).not.toBe(oldFinal.generation);
    expect(gate.replayParsed(current.generation)).toBe(true);
  });

  it("abandons a truncated multi-batch replay when the channel rejoins", () => {
    const gate = createStreamGate();
    const truncated = gate.replayBatch(10, false);
    expect(truncated.firstBatch).toBe(true);

    // The old connection vanished before its done batch. The first snapshot
    // on the replacement connection is a new wire replay, not the old tail.
    gate.joined();
    const replacement = gate.replayBatch(3, true);

    expect(replacement.firstBatch).toBe(true);
    expect(replacement.reset).toBe(true);
    expect(replacement.generation).not.toBe(truncated.generation);
    expect(gate.replayParsed(replacement.generation)).toBe(true);
    expect(gate.acceptInput()).toBe(true);
  });

  it("accepts everything for an empty session (replay seq -1)", () => {
    const gate = createStreamGate();
    const replay = gate.replayBatch(-1, true);
    gate.replayParsed(replay.generation);

    expect(gate.acceptOutput(0)).toBe(true);
    expect(gate.acceptInput()).toBe(true);
  });
});

describe("flow-control skip repaint", () => {
  it("mid-session flow replay resets, rebaselines seq and guards input", () => {
    const gate = createStreamGate();
    gate.joined();
    const initial = gate.replayBatch(10, true);
    expect(initial).toMatchObject({ reset: true, release: true });
    gate.replayParsed(initial.generation);
    expect(gate.acceptOutput(11)).toBe(true);
    expect(gate.acceptOutput(12)).toBe(true);

    // Link fell behind: server skipped seqs 13..99 and sends a repaint.
    // The client treats it as a fresh join so the screen resets.
    gate.joined();
    const flow = gate.replayBatch(100, true);
    expect(flow.reset).toBe(true);
    expect(flow.release).toBe(true);
    // auto-responses to replayed escape sequences must not reach the PTY
    gate.parseStarted();
    expect(gate.acceptInput()).toBe(false);
    gate.parseFinished();
    gate.replayParsed(flow.generation);
    expect(gate.acceptInput()).toBe(true);

    // pre-skip stragglers are dropped, post-repaint output flows
    expect(gate.acceptOutput(99)).toBe(false);
    expect(gate.acceptOutput(101)).toBe(true);
  });
});
