import { describe, expect, it } from "vitest";
import { isSizeFollower } from "./sizeRole";

describe("isSizeFollower", () => {
  it("is a driver when ownership is free (fresh session / owner left)", () => {
    expect(isSizeFollower("me", null)).toBe(false);
    expect(isSizeFollower("me", undefined)).toBe(false);
  });

  it("is a driver when this client owns the size", () => {
    expect(isSizeFollower("me", "me")).toBe(false);
  });

  it("is a follower when another client owns the size", () => {
    expect(isSizeFollower("me", "other")).toBe(true);
  });

  it("follows an owner even before knowing its own id (late join reply race)", () => {
    expect(isSizeFollower(null, "other")).toBe(true);
    expect(isSizeFollower(undefined, "other")).toBe(true);
  });

  it("drives against legacy servers that never report ownership", () => {
    expect(isSizeFollower(null, undefined)).toBe(false);
    expect(isSizeFollower(null, null)).toBe(false);
  });
});
