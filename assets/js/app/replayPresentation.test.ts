import { describe, expect, it } from "vitest";
import {
  joinHistoryBatches,
  replayBatchPlan,
  replayCoverTransition,
  replayPresentation,
  shouldDiscardHiddenOutput,
  type ReplayTrigger,
} from "./replayPresentation";

describe("replay presentation", () => {
  it.each([
    ["initial", false, "cover"],
    ["catch-up", false, "cover"],
    ["flow", false, "cover"],
    ["catch-up", true, "preserve"],
    ["flow", true, "preserve"],
    ["reset", true, "cover"],
  ] as const)(
    "%s replay with frame=%s uses the %s presentation",
    (trigger: ReplayTrigger, hasFrame: boolean, expected: "cover" | "preserve") => {
      expect(replayPresentation(trigger, hasFrame)).toBe(expected);
    },
  );

  it("covers immediately and animates only the settled reveal", () => {
    expect(replayCoverTransition(true)).toBe("opacity-100 transition-none");
    expect(replayCoverTransition(false)).toBe("opacity-0 transition-opacity duration-150");
  });

  it.each([
    [
      "single-batch warm reset with RIS",
      "preserve",
      true,
      true,
      new Uint8Array([0x1b, 0x63, 0x41]),
      { presentation: "preserve", resetBeforeWrite: false },
    ],
    [
      "multi-batch warm reset",
      "preserve",
      true,
      false,
      new Uint8Array([0x1b, 0x63, 0x41]),
      { presentation: "cover", resetBeforeWrite: false },
    ],
    [
      "warm reset without RIS",
      "preserve",
      true,
      true,
      new Uint8Array([0x41]),
      { presentation: "cover", resetBeforeWrite: true },
    ],
    [
      "empty warm reset",
      "preserve",
      true,
      true,
      "",
      { presentation: "cover", resetBeforeWrite: true },
    ],
    [
      "covered reset with RIS",
      "cover",
      true,
      true,
      new Uint8Array([0x1b, 0x63]),
      { presentation: "cover", resetBeforeWrite: false },
    ],
    [
      "non-reset batch",
      "preserve",
      false,
      false,
      new Uint8Array([0x41]),
      { presentation: "preserve", resetBeforeWrite: false },
    ],
  ] as const)("plans %s safely", (_name, presentation, reset, done, data, expected) => {
    expect(replayBatchPlan(presentation, reset, done, data)).toEqual(expected);
  });

  it.each([
    ["catch-up", false, true, true],
    ["catch-up", false, false, false],
    ["catch-up", true, true, false],
    ["flow", false, true, false],
    ["reset", false, true, false],
    ["initial", false, true, false],
  ] as const)(
    "hidden output cleanup: %s reset=%s empty=%s -> %s",
    (trigger, reset, empty, expected) => {
      expect(shouldDiscardHiddenOutput(trigger, reset, empty)).toBe(expected);
    },
  );

  describe("history loads", () => {
    it("keeps the frame the user is reading", () => {
      expect(replayPresentation("history", true)).toBe("preserve");
    });

    it("still covers a cold attach — there is no frame to keep", () => {
      expect(replayPresentation("history", false)).toBe("cover");
    });

    it("planned as one completed batch, it needs no cover", () => {
      const snapshot = new TextEncoder().encode("\u001bcscrollback");
      expect(replayBatchPlan("preserve", true, true, snapshot)).toEqual({
        presentation: "preserve",
        resetBeforeWrite: false,
      });
    });
  });

  describe("joinHistoryBatches", () => {
    const bytes = (...values: number[]) => new Uint8Array(values);

    it("concatenates the held batches with the final one", () => {
      expect(joinHistoryBatches([bytes(1, 2), bytes(3)], bytes(4, 5))).toEqual(bytes(1, 2, 3, 4, 5));
    });

    it("returns the single batch untouched", () => {
      const only = bytes(7, 8);
      expect(joinHistoryBatches([], only)).toBe(only);
    });

    it("drops an empty final payload (the holder-unavailable sentinel)", () => {
      expect(joinHistoryBatches([bytes(1)], "")).toEqual(bytes(1));
      expect(joinHistoryBatches([], "")).toBe("");
    });
  });
});
