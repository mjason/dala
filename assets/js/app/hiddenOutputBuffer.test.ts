import { describe, expect, it } from "vitest";
import { createHiddenOutputBuffer } from "./hiddenOutputBuffer";

const bytes = (...values: number[]) => new Uint8Array(values);

describe("hidden terminal output buffer", () => {
  it("buffers a bounded tail and drains it in wire order", () => {
    const buffer = createHiddenOutputBuffer(5);
    expect(buffer.push(bytes(1, 2))).toEqual({ dirty: false, droppedBytes: 0 });
    expect(buffer.push(bytes(3, 4, 5))).toEqual({ dirty: false, droppedBytes: 0 });
    expect([...buffer.drain()]).toEqual([1, 2, 3, 4, 5]);
    expect(buffer.byteLength()).toBe(0);
  });

  it("drops the entire backlog on overflow and stays dirty", () => {
    const buffer = createHiddenOutputBuffer(4);
    buffer.push(bytes(1, 2, 3));

    expect(buffer.push(bytes(4, 5))).toEqual({ dirty: true, droppedBytes: 5 });
    expect(buffer.push(bytes(6, 7))).toEqual({ dirty: true, droppedBytes: 2 });
    expect(buffer.isDirty()).toBe(true);
    expect(buffer.drain()).toHaveLength(0);
  });

  it("reset starts a fresh bounded window after a screen catch-up", () => {
    const buffer = createHiddenOutputBuffer(1);
    buffer.push(bytes(1, 2));
    buffer.reset();

    expect(buffer.isDirty()).toBe(false);
    expect(buffer.push(bytes(3))).toEqual({ dirty: false, droppedBytes: 0 });
    expect([...buffer.drain()]).toEqual([3]);
  });
});
