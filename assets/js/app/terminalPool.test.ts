import { describe, expect, it } from "vitest";
import { nextWarmSession, terminalWarmLimit, touchTerminalPool } from "./terminalPool";

describe("terminal warm pool", () => {
  it("keeps the common ten-session desktop workspace warm", () => {
    expect(terminalWarmLimit({ coarsePointer: false })).toBe(10);
    expect(terminalWarmLimit({ coarsePointer: false, deviceMemory: 8 })).toBe(10);
  });

  it("uses conservative limits on low-memory and touch-first devices", () => {
    expect(terminalWarmLimit({ coarsePointer: false, deviceMemory: 4 })).toBe(6);
    expect(terminalWarmLimit({ coarsePointer: true, deviceMemory: 16 })).toBe(3);
  });

  it("caps full-size terminal canvases on high-DPR and very large displays", () => {
    expect(
      terminalWarmLimit({
        coarsePointer: false,
        deviceMemory: 8,
        devicePixelRatio: 2,
        viewportWidth: 1440,
        viewportHeight: 900,
      }),
    ).toBe(4);
    expect(
      terminalWarmLimit({
        coarsePointer: false,
        deviceMemory: 8,
        devicePixelRatio: 2,
        viewportWidth: 1920,
        viewportHeight: 1080,
      }),
    ).toBe(2);
    expect(
      terminalWarmLimit({
        coarsePointer: false,
        deviceMemory: 4,
        devicePixelRatio: 2,
        viewportWidth: 1440,
        viewportHeight: 900,
      }),
    ).toBe(2);
  });

  it("touches the active session without evicting until the limit is full", () => {
    expect(touchTerminalPool(["a", "b"], "c", 4)).toEqual(["c", "a", "b"]);
    expect(touchTerminalPool(["c", "a", "b"], "a", 4)).toEqual(["a", "c", "b"]);
    expect(touchTerminalPool(["a", "b", "c", "d"], "e", 4)).toEqual([
      "e",
      "a",
      "b",
      "c",
    ]);
  });

  it("idle-warms the first preferred session without evicting a hot one", () => {
    expect(nextWarmSession(["active"], ["active", "recent", "older"], 3)).toBe("recent");
    expect(nextWarmSession(["active", "recent", "older"], ["cold"], 3)).toBeNull();
  });
});
