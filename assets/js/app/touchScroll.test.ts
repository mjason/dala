import { describe, expect, it } from "vitest";
import {
  createLineAccumulator,
  createTouchPan,
  decayVelocity,
  FLICK_MAX_GAP_MS,
  MIN_COAST_VELOCITY,
  PAN_SLOP_PX,
  touchScrollRoute,
} from "./touchScroll";

describe("touchScrollRoute", () => {
  it("routes the normal buffer to direct line scrolling", () => {
    expect(touchScrollRoute("normal", "none")).toBe("lines");
  });

  it("routes the alt buffer to synthetic wheel (arrow conversion)", () => {
    expect(touchScrollRoute("alternate", "none")).toBe("wheel");
  });

  it("routes wheel-capable mouse tracking to synthetic wheel on any buffer", () => {
    expect(touchScrollRoute("normal", "vt200")).toBe("wheel");
    expect(touchScrollRoute("alternate", "drag")).toBe("wheel");
    expect(touchScrollRoute("alternate", "any")).toBe("wheel");
  });

  it("x10 tracking has no wheel reports: normal buffer still scrolls lines", () => {
    expect(touchScrollRoute("normal", "x10")).toBe("lines");
    expect(touchScrollRoute("alternate", "x10")).toBe("wheel");
  });
});

describe("createLineAccumulator", () => {
  it("converts accumulated pixels into whole lines with remainder carry", () => {
    const acc = createLineAccumulator();
    // 3 × 7px at 17px cells: nothing, nothing, then one line (21px ≥ 17px).
    expect(acc.add(7, 17)).toBe(0);
    expect(acc.add(7, 17)).toBe(0);
    expect(acc.add(7, 17)).toBe(1);
    // 4px carried over; 13px more completes the next line exactly.
    expect(acc.add(13, 17)).toBe(1);
  });

  it("handles downward and upward scrolling symmetrically", () => {
    const acc = createLineAccumulator();
    expect(acc.add(40, 17)).toBe(2); // 6px carry
    expect(acc.add(-40, 17)).toBe(-2); // carry back through zero
  });

  it("emits multiple lines for one large step", () => {
    const acc = createLineAccumulator();
    expect(acc.add(170, 17)).toBe(10);
  });

  it("reset drops the carry", () => {
    const acc = createLineAccumulator();
    acc.add(16, 17);
    acc.reset();
    expect(acc.add(16, 17)).toBe(0);
  });

  it("ignores nonsense cell heights instead of dividing by zero", () => {
    const acc = createLineAccumulator();
    expect(acc.add(100, 0)).toBe(0);
    expect(acc.add(100, NaN)).toBe(0);
  });
});

describe("createTouchPan", () => {
  it("stays pending inside the slop radius (taps are not hijacked)", () => {
    const pan = createTouchPan();
    pan.start(100, 100, 0);
    expect(pan.move(102, 103, 16).phase).toBe("pending");
    expect(pan.end(30)).toBe(0);
  });

  it("locks to ignored on a horizontal gesture and never converts back", () => {
    const pan = createTouchPan();
    pan.start(100, 100, 0);
    expect(pan.move(100 + PAN_SLOP_PX + 4, 101, 16).phase).toBe("ignored");
    // Later vertical movement stays ignored: the axis lock is per gesture.
    expect(pan.move(120, 160, 32).phase).toBe("ignored");
  });

  it("owns a vertical gesture and reports natural-scroll pixels", () => {
    const pan = createTouchPan();
    pan.start(100, 100, 0);
    // Cross the slop: first pan step consumes the slop (scrollPx 0).
    const lock = pan.move(101, 100 + PAN_SLOP_PX + 2, 16);
    expect(lock).toEqual({ phase: "pan", scrollPx: 0 });
    // Finger moves DOWN 30px → content follows → scroll UP 30px.
    const down = pan.move(101, 140, 32);
    expect(down).toEqual({ phase: "pan", scrollPx: -30 });
    // Finger moves UP 20px → scroll DOWN 20px.
    const up = pan.move(101, 120, 48);
    expect(up).toEqual({ phase: "pan", scrollPx: 20 });
  });

  it("reports a flick velocity on a fast release", () => {
    const pan = createTouchPan();
    pan.start(100, 200, 0);
    pan.move(100, 180, 16); // locks vertical
    pan.move(100, 140, 32); // 40px up in 16ms → scroll down fast
    const v = pan.end(40);
    expect(v).toBeGreaterThan(1); // scrollPx/ms, positive = keep scrolling down
  });

  it("does not flick when the finger rested before lifting", () => {
    const pan = createTouchPan();
    pan.start(100, 200, 0);
    pan.move(100, 180, 16);
    pan.move(100, 140, 32);
    expect(pan.end(32 + FLICK_MAX_GAP_MS + 50)).toBe(0);
  });

  it("does not flick on a slow drag", () => {
    const pan = createTouchPan();
    pan.start(100, 200, 0);
    pan.move(100, 180, 100);
    pan.move(100, 170, 300); // 10px over 200ms = 0.05 px/ms
    expect(pan.end(320)).toBe(0);
  });

  it("cancel aborts the gesture (second finger, touchcancel)", () => {
    const pan = createTouchPan();
    pan.start(100, 100, 0);
    pan.move(100, 130, 16);
    pan.cancel();
    expect(pan.move(100, 200, 32).phase).toBe("ignored");
    expect(pan.end(48)).toBe(0);
  });

  it("moves without start are ignored", () => {
    const pan = createTouchPan();
    expect(pan.move(10, 10, 0).phase).toBe("ignored");
  });
});

describe("decayVelocity", () => {
  it("decays exponentially toward zero", () => {
    const v1 = decayVelocity(2, 100);
    expect(v1).toBeLessThan(2);
    expect(v1).toBeGreaterThan(0);
    expect(decayVelocity(v1, 100)).toBeLessThan(v1);
  });

  it("preserves the sign of the velocity", () => {
    expect(decayVelocity(-2, 100)).toBeLessThan(0);
  });

  it("a strong flick falls under the coast threshold within ~1.5s", () => {
    let v = 3;
    let t = 0;
    while (Math.abs(v) >= MIN_COAST_VELOCITY && t < 5000) {
      v = decayVelocity(v, 16);
      t += 16;
    }
    expect(t).toBeLessThan(1500);
  });
});
