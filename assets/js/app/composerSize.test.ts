import { describe, expect, it } from "vitest";
import {
  COMPOSER_MAX_HEIGHT,
  COMPOSER_MIN_HEIGHT,
  COMPOSER_MIN_HEIGHT_TOUCH,
  composerSizing,
} from "./composerSize";

// jsdom cannot lay out CodeMirror (every offsetHeight is 0), so the height
// policy is pinned here as a pure CSS spec; e2e measures the real pixels.
describe("composerSizing", () => {
  it("normal mode grows with content: no fixed height, only a floor and a cap", () => {
    const spec = composerSizing(false);
    // No fixed height — CodeMirror sizes to its content…
    expect(spec["&"].height).toBeUndefined();
    // …bounded so the composer can never cover the terminal…
    expect(spec["&"].maxHeight).toBe(COMPOSER_MAX_HEIGHT);
    // …and never collapses below the old fixed height when empty.
    expect(spec[".cm-content"].minHeight).toBe(COMPOSER_MIN_HEIGHT);
  });

  it("caps at ≤45% of the viewport so the terminal stays visible", () => {
    const vhMatch = COMPOSER_MAX_HEIGHT.match(/min\((\d+(?:\.\d+)?)vh,/);
    expect(vhMatch).not.toBeNull();
    const vh = Number(vhMatch![1]);
    expect(vh).toBeGreaterThan(0);
    expect(vh).toBeLessThanOrEqual(45);
  });

  it("honors the visual viewport (--vvh) so the soft keyboard shrinks the cap too", () => {
    // vh units ignore the soft keyboard on mobile; the cap must take the
    // smaller of layout-vh and visual-viewport fractions.
    expect(COMPOSER_MAX_HEIGHT).toContain("var(--vvh");
    expect(COMPOSER_MAX_HEIGHT).toContain("100vh"); // desktop fallback
    expect(COMPOSER_MAX_HEIGHT.startsWith("min(")).toBe(true);
  });

  it("floors the empty editor at ~3 lines, in line with the git commit box", () => {
    // 4.5rem = 72px: 12px of .cm-content padding + ~2.9 lines of 14px/1.5
    // text. The old 7.5rem floor was ~5 lines and stole terminal rows while
    // the composer sat empty.
    expect(COMPOSER_MIN_HEIGHT).toBe("4.5rem");
    expect(parseFloat(COMPOSER_MIN_HEIGHT)).toBeLessThan(7.5);
  });

  it("touch keeps a taller floor: 16px text needs more room for the same 3 lines", () => {
    // 5.25rem = 84px = 12px padding + 3 × 24px lines (16px/1.5 on coarse
    // pointers, where the font is bumped to dodge iOS auto-zoom).
    expect(COMPOSER_MIN_HEIGHT_TOUCH).toBe("5.25rem");
    expect(parseFloat(COMPOSER_MIN_HEIGHT_TOUCH)).toBeGreaterThan(
      parseFloat(COMPOSER_MIN_HEIGHT),
    );
    expect(composerSizing(false, true)[".cm-content"].minHeight).toBe(COMPOSER_MIN_HEIGHT_TOUCH);
    expect(composerSizing(false, false)[".cm-content"].minHeight).toBe(COMPOSER_MIN_HEIGHT);
  });

  it("the floor never applies in fullscreen (the host owns the height)", () => {
    expect(composerSizing(true, true)[".cm-content"]).toBeUndefined();
  });

  it("scrolls internally beyond the bound in both modes", () => {
    expect(composerSizing(false)[".cm-scroller"].overflowY).toBe("auto");
    expect(composerSizing(true)[".cm-scroller"].overflowY).toBe("auto");
  });

  it("fullscreen fills the host instead of capping", () => {
    const spec = composerSizing(true);
    expect(spec["&"].height).toBe("100%");
    expect(spec["&"].maxHeight).toBeUndefined();
  });
});
