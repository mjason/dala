import { afterEach, describe, expect, it, vi } from "vitest";
import { checkServerUpdated, fetchServerVersion, serverChanged } from "./versionCheck";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("serverChanged", () => {
  it("is true when both versions are known and differ", () => {
    expect(serverChanged("0.16.0", "0.16.2")).toBe(true);
  });

  it("is false when the versions match", () => {
    expect(serverChanged("0.16.2", "0.16.2")).toBe(false);
  });

  it("ignores surrounding whitespace", () => {
    expect(serverChanged("0.16.2", " 0.16.2\n")).toBe(false);
    expect(serverChanged(" 0.16.0", "0.16.2")).toBe(true);
  });

  it("stays quiet when either side is unknown", () => {
    expect(serverChanged(null, "0.16.2")).toBe(false);
    expect(serverChanged("0.16.2", null)).toBe(false);
    expect(serverChanged("", "0.16.2")).toBe(false);
    expect(serverChanged("0.16.2", "  ")).toBe(false);
    expect(serverChanged(null, null)).toBe(false);
  });
});

describe("fetchServerVersion", () => {
  it("returns the trimmed body on success", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("0.17.0\n", { status: 200 })),
    );
    expect(await fetchServerVersion()).toBe("0.17.0");
  });

  it("returns null on a non-2xx response", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 503 })));
    expect(await fetchServerVersion()).toBeNull();
  });

  it("returns null when the request throws (server restarting)", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("network down");
      }),
    );
    expect(await fetchServerVersion()).toBeNull();
  });

  it("returns null on an empty body", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 200 })));
    expect(await fetchServerVersion()).toBeNull();
  });
});

describe("checkServerUpdated", () => {
  it("reports an update when the served version differs from the embedded one", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("0.17.0", { status: 200 })),
    );
    expect(await checkServerUpdated("0.16.2")).toBe(true);
  });

  it("reports nothing when versions match", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("0.16.2", { status: 200 })),
    );
    expect(await checkServerUpdated("0.16.2")).toBe(false);
  });

  it("skips the fetch entirely without an embedded version", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    expect(await checkServerUpdated(null)).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
