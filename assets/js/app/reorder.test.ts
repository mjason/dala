import { describe, expect, it } from "vitest";
import {
  applyReorder,
  beforeIdFor,
  byPosition,
  insertionIndex,
  positionBefore,
} from "./reorder";

const s = (id: string, position: number, insertedAt = "2026-01-01T00:00:00Z") => ({
  id,
  position,
  insertedAt,
});

describe("byPosition", () => {
  it("orders by position, then insertedAt on ties", () => {
    const list = [
      s("late-tie", 2, "2026-01-02T00:00:00Z"),
      s("c", 3),
      s("a", 1),
      s("early-tie", 2, "2026-01-01T00:00:00Z"),
    ];
    expect([...list].sort(byPosition).map((x) => x.id)).toEqual([
      "a",
      "early-tie",
      "late-tie",
      "c",
    ]);
  });
});

describe("insertionIndex", () => {
  // Row midpoints at y = 10, 30, 50; dragging the row at index 2.
  const mids = [10, 30, 50];

  it("maps the pointer y to a slot, skipping the dragged row", () => {
    expect(insertionIndex(mids, 2, 5)).toBe(0); // above everything
    expect(insertionIndex(mids, 2, 20)).toBe(1); // between rows 0 and 1
    expect(insertionIndex(mids, 2, 40)).toBe(2); // below both remaining rows
    expect(insertionIndex(mids, 2, 999)).toBe(2); // way past the end
  });

  it("ignores the dragged row's own midpoint", () => {
    expect(insertionIndex(mids, 0, 15)).toBe(0); // 15 > 10 but 10 is dragged
  });
});

describe("beforeIdFor", () => {
  const list = [s("a", 1), s("b", 2), s("c", 3)];

  it("returns the id occupying the slot, excluding the dragged row", () => {
    expect(beforeIdFor(list, "c", 0)).toBe("a");
    expect(beforeIdFor(list, "c", 1)).toBe("b");
  });

  it("returns null for the end slot", () => {
    expect(beforeIdFor(list, "a", 2)).toBeNull();
  });
});

describe("positionBefore (mirrors the server's midpoint scheme)", () => {
  const list = [s("a", 1), s("b", 2), s("c", 3)];

  it("halves the first position when moving to the front", () => {
    expect(positionBefore(list, "c", "a")).toBe(0.5);
  });

  it("takes the midpoint of the new neighbours", () => {
    expect(positionBefore(list, "a", "c")).toBe(2.5);
  });

  it("appends after the last for a null or unknown beforeId", () => {
    expect(positionBefore(list, "a", null)).toBe(4);
    expect(positionBefore(list, "a", "deleted-elsewhere")).toBe(4);
  });

  it("sorts its input first (state lists are unsorted)", () => {
    const shuffled = [list[2], list[0], list[1]];
    expect(positionBefore(shuffled, "a", "c")).toBe(2.5);
  });
});

describe("applyReorder", () => {
  it("moves only the dragged session's position, immutably", () => {
    const list = [s("a", 1), s("b", 2), s("c", 3)];
    const next = applyReorder(list, "c", "a");
    expect(next.find((x) => x.id === "c")?.position).toBe(0.5);
    expect(next.filter((x) => x.id !== "c")).toEqual(list.filter((x) => x.id !== "c"));
    expect(list.find((x) => x.id === "c")?.position).toBe(3);
    expect([...next].sort(byPosition).map((x) => x.id)).toEqual(["c", "a", "b"]);
  });
});
