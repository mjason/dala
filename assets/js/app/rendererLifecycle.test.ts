import { describe, expect, it, vi } from "vitest";
import { recoverOwnedWebglContext } from "./rendererLifecycle";

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
