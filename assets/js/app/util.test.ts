import { describe, expect, it } from "vitest";
import { base64ToBytes, humanBytes, shortPath, timeAgo } from "./util";

describe("base64ToBytes", () => {
  it("decodes to raw bytes", () => {
    expect(Array.from(base64ToBytes("aGk="))).toEqual([104, 105]);
    expect(Array.from(base64ToBytes(""))).toEqual([]);
  });

  it("roundtrips binary content", () => {
    const bytes = new Uint8Array([0, 1, 27, 91, 255]);
    const b64 = btoa(String.fromCharCode(...bytes));
    expect(Array.from(base64ToBytes(b64))).toEqual(Array.from(bytes));
  });
});

describe("humanBytes", () => {
  it("formats sizes", () => {
    expect(humanBytes(512)).toBe("512 B");
    expect(humanBytes(2048)).toBe("2.0 KB");
    expect(humanBytes(5 * 1024 * 1024)).toBe("5.0 MB");
    expect(humanBytes(15 * 1024 * 1024)).toBe("15 MB");
  });
});

describe("shortPath", () => {
  it("keeps short paths", () => {
    expect(shortPath("/home/mj")).toBe("/home/mj");
  });

  it("shortens long paths to their tail", () => {
    const long = "/home/mj/dev/elixir/dala/lib/dala_web/components";
    expect(shortPath(long, 20)).toBe("…/components");
  });
});

describe("timeAgo", () => {
  it("handles null and recent times", () => {
    expect(timeAgo(null)).toBe("");
    expect(timeAgo(new Date().toISOString())).toBe("just now");
  });

  it("reports minutes and hours", () => {
    expect(timeAgo(new Date(Date.now() - 5 * 60_000).toISOString())).toBe("5m ago");
    expect(timeAgo(new Date(Date.now() - 3 * 3_600_000).toISOString())).toBe("3h ago");
  });
});
