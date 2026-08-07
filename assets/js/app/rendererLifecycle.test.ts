import { describe, expect, it, vi } from "vitest";
import { createWarmRendererPool, recoverOwnedWebglContext } from "./rendererLifecycle";

describe("WebGL renderer lifecycle", () => {
  it("ignores a delayed loss from an addon that no longer owns the renderer", () => {
    const dispose = vi.fn();

    expect(recoverOwnedWebglContext(1, 2, dispose)).toBe(false);
    expect(dispose).not.toHaveBeenCalled();
  });

  it("recovers the addon that still owns the renderer", () => {
    const recover = vi.fn();

    expect(recoverOwnedWebglContext(2, 2, recover)).toBe(true);
    expect(recover).toHaveBeenCalledOnce();
  });
});

describe("warm renderer pool", () => {
  it("keeps the terminal you just left and releases the one before it", () => {
    const pool = createWarmRendererPool(1);
    const releaseA = vi.fn();
    const releaseB = vi.fn();

    expect(pool.retain("a", releaseA)).toBe(true);
    expect(releaseA).not.toHaveBeenCalled();

    // Switching on to a third tab evicts the oldest warm renderer.
    expect(pool.retain("b", releaseB)).toBe(true);
    expect(releaseA).toHaveBeenCalledOnce();
    expect(releaseB).not.toHaveBeenCalled();
    expect(pool.warm()).toEqual(["b"]);
  });

  it("never releases a terminal that came back on screen", () => {
    const pool = createWarmRendererPool(1);
    const release = vi.fn();

    pool.retain("a", release);
    pool.forget("a");
    expect(release).not.toHaveBeenCalled();
    expect(pool.warm()).toEqual([]);

    // ...and it is no longer evictable by a later hide.
    pool.retain("b", vi.fn());
    expect(release).not.toHaveBeenCalled();
  });

  it("re-hiding the same view refreshes it instead of double-counting", () => {
    const pool = createWarmRendererPool(2);
    const release = vi.fn();

    pool.retain("a", release);
    pool.retain("b", vi.fn());
    pool.retain("a", release);

    expect(pool.warm()).toEqual(["a", "b"]);
    expect(release).not.toHaveBeenCalled();
  });

  it("tells the caller to tear down immediately when warming is disabled", () => {
    const pool = createWarmRendererPool(0);
    const release = vi.fn();

    expect(pool.retain("a", release)).toBe(false);
    expect(release).not.toHaveBeenCalled();
    expect(pool.warm()).toEqual([]);
  });
});
