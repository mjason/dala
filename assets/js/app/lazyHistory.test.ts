import { describe, expect, it } from "vitest";
import { createLazyHistory } from "./lazyHistory";

describe("lazy terminal history", () => {
  it("deduplicates requests and releases the original user intent after parsing", () => {
    const history = createLazyHistory();

    expect(history.request("scroll")).toBe(true);
    expect(history.request("find")).toBe(false);
    expect(history.finishReplay(true)).toBe("scroll");
    expect(history.isLoaded()).toBe(true);
  });

  it("does not request history when an old holder already sent it on attach", () => {
    const history = createLazyHistory();

    expect(history.finishReplay(true)).toBeNull();
    expect(history.request("find")).toBe(false);
  });

  it("becomes lazy again after a viewport-only catch-up reset", () => {
    const history = createLazyHistory();
    history.finishReplay(true);
    history.finishReplay(false);

    expect(history.isLoaded()).toBe(false);
    expect(history.request("find")).toBe(true);
  });
});
