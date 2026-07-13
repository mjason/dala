import { beforeEach, describe, expect, it, vi } from "vitest";

// The module memoizes the id (localStorage can be unavailable), so each test
// that needs a pristine module state imports a fresh instance.
async function freshModule() {
  vi.resetModules();
  return import("./deviceId");
}

const KEY = "dala:device-id";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

beforeEach(() => {
  localStorage.clear();
  vi.restoreAllMocks();
});

describe("getDeviceId", () => {
  it("generates a UUID and persists it under dala:device-id", async () => {
    const { getDeviceId } = await freshModule();
    const id = getDeviceId();
    expect(id).toMatch(UUID_RE);
    expect(localStorage.getItem(KEY)).toBe(id);
  });

  it("is stable across calls", async () => {
    const { getDeviceId } = await freshModule();
    expect(getDeviceId()).toBe(getDeviceId());
  });

  it("adopts an id another tab already stored", async () => {
    localStorage.setItem(KEY, "stored-device-id");
    const { getDeviceId } = await freshModule();
    expect(getDeviceId()).toBe("stored-device-id");
  });

  it("prefers the stored id over its own memo (another tab may have raced the write)", async () => {
    const { getDeviceId } = await freshModule();
    getDeviceId();
    localStorage.setItem(KEY, "other-tab-id");
    expect(getDeviceId()).toBe("other-tab-id");
  });

  it("survives localStorage being unavailable with a stable in-memory id", async () => {
    const { getDeviceId } = await freshModule();
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("denied");
    });
    const id = getDeviceId();
    expect(id).toMatch(UUID_RE);
    expect(getDeviceId()).toBe(id);
  });

  it("falls back to a random UUID shape without crypto.randomUUID", async () => {
    const original = crypto.randomUUID;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (crypto as any).randomUUID = undefined;
    try {
      const { getDeviceId } = await freshModule();
      expect(getDeviceId()).toMatch(UUID_RE);
    } finally {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (crypto as any).randomUUID = original;
    }
  });
});
