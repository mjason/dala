import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  DEFAULT_SPEECH_PREFS,
  dropLegacySpeechPrefs,
  ensureLegacySpeechMigrated,
  loadSpeechPrefs,
  migrateLegacySpeechPrefs,
  readLegacySpeechPrefs,
  resetSpeechMigrationGuard,
  saveSpeechPrefs,
} from "./speech";

const KEY = "dala:speech-prefs";

beforeEach(() => {
  localStorage.clear();
  resetSpeechMigrationGuard();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("loadSpeechPrefs", () => {
  it("returns the defaults when nothing is stored", () => {
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);
  });

  it("returns the defaults for garbage JSON", () => {
    localStorage.setItem(KEY, "{not json at all");
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);
  });

  it("returns the defaults for JSON that is not an object", () => {
    localStorage.setItem(KEY, "null");
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);

    localStorage.setItem(KEY, '"just a string"');
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);
  });

  it("keeps ONLY micDeviceId — the endpoint/model/key now live on the server", () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({
        micDeviceId: "device-42",
        endpoint: "http://x/v1",
        model: "whisper-tiny",
        apiKey: "sk-secret",
        evil: "payload",
      }),
    );

    const prefs = loadSpeechPrefs();
    expect(prefs).toEqual({ micDeviceId: "device-42" });
    expect(Object.keys(prefs)).toEqual(["micDeviceId"]);
  });

  it("falls back when the stored value has the wrong type", () => {
    localStorage.setItem(KEY, JSON.stringify({ micDeviceId: ["x"] }));
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);
  });

  it("returns the defaults when storage itself throws", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage unavailable");
    });
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);
  });
});

describe("saveSpeechPrefs", () => {
  it("persists micDeviceId and nothing else", () => {
    saveSpeechPrefs({ micDeviceId: "device-1" });

    const stored: unknown = JSON.parse(localStorage.getItem(KEY) ?? "{}");
    expect(stored).toEqual({ micDeviceId: "device-1" });
    expect(loadSpeechPrefs().micDeviceId).toBe("device-1");
  });

  it("never lets an endpoint/model/api key back into storage", () => {
    // A stale caller (or an old bundle in another tab) can't smuggle them in.
    saveSpeechPrefs({
      micDeviceId: "d",
      endpoint: "http://x/v1",
      apiKey: "sk-1",
    } as never);

    expect(localStorage.getItem(KEY)).not.toContain("endpoint");
    expect(localStorage.getItem(KEY)).not.toContain("sk-1");
  });

  it("overwrites a previously saved device", () => {
    saveSpeechPrefs({ micDeviceId: "old" });
    saveSpeechPrefs({ micDeviceId: "new" });
    expect(loadSpeechPrefs().micDeviceId).toBe("new");
  });

  it("still returns the merged prefs when storage writes fail", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota exceeded");
    });
    expect(saveSpeechPrefs({ micDeviceId: "d" }).micDeviceId).toBe("d");
  });
});

describe("legacy prefs (the localStorage era)", () => {
  const seedLegacy = (extra: Record<string, unknown> = {}) =>
    localStorage.setItem(
      KEY,
      JSON.stringify({
        endpoint: "http://127.0.0.1:8000/v1",
        model: "whisper-tiny",
        apiKey: "sk-legacy",
        micDeviceId: "device-9",
        ...extra,
      }),
    );

  it("reads the old endpoint/model/key back out", () => {
    seedLegacy();
    expect(readLegacySpeechPrefs()).toEqual({
      endpoint: "http://127.0.0.1:8000/v1",
      model: "whisper-tiny",
      apiKey: "sk-legacy",
    });
  });

  it("is null when there is no legacy endpoint", () => {
    expect(readLegacySpeechPrefs()).toBe(null);
    saveSpeechPrefs({ micDeviceId: "device-9" });
    expect(readLegacySpeechPrefs()).toBe(null);
  });

  it("dropping them keeps micDeviceId", () => {
    seedLegacy();
    dropLegacySpeechPrefs();

    expect(readLegacySpeechPrefs()).toBe(null);
    expect(loadSpeechPrefs().micDeviceId).toBe("device-9");
    expect(localStorage.getItem(KEY)).not.toContain("sk-legacy");
  });
});

describe("migrateLegacySpeechPrefs", () => {
  it("pushes local prefs to an empty server, then clears them locally", async () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({
        endpoint: "http://127.0.0.1:8000/v1",
        model: "whisper-tiny",
        apiKey: "sk-legacy",
        micDeviceId: "device-9",
      }),
    );
    const push = vi.fn().mockResolvedValue(true);

    const migrated = await migrateLegacySpeechPrefs({ endpoint: "" }, push);

    expect(push).toHaveBeenCalledWith({
      endpoint: "http://127.0.0.1:8000/v1",
      model: "whisper-tiny",
      apiKey: "sk-legacy",
    });
    expect(migrated?.endpoint).toBe("http://127.0.0.1:8000/v1");
    // legacy keys gone, device pref kept
    expect(readLegacySpeechPrefs()).toBe(null);
    expect(loadSpeechPrefs().micDeviceId).toBe("device-9");
  });

  it("never clobbers an existing server config — it just cleans up locally", async () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({
        endpoint: "http://local/v1",
        model: "m",
        apiKey: "sk-legacy",
      }),
    );
    const push = vi.fn().mockResolvedValue(true);

    const migrated = await migrateLegacySpeechPrefs(
      { endpoint: "http://server/v1" },
      push,
    );

    expect(push).not.toHaveBeenCalled();
    expect(migrated).toBe(null);
    expect(readLegacySpeechPrefs()).toBe(null);
  });

  it("does nothing when there is nothing to migrate", async () => {
    const push = vi.fn().mockResolvedValue(true);
    expect(await migrateLegacySpeechPrefs({ endpoint: "" }, push)).toBe(null);
    expect(push).not.toHaveBeenCalled();
  });

  it("keeps the legacy prefs when the push fails (retry on the next open)", async () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({ endpoint: "http://local/v1", model: "m" }),
    );
    const push = vi.fn().mockResolvedValue(false);

    expect(await migrateLegacySpeechPrefs({ endpoint: "" }, push)).toBe(null);
    expect(readLegacySpeechPrefs()?.endpoint).toBe("http://local/v1");
  });
});

describe("ensureLegacySpeechMigrated (fires at app mount)", () => {
  const seedLegacy = () =>
    localStorage.setItem(
      KEY,
      JSON.stringify({
        endpoint: "http://127.0.0.1:8000/v1",
        model: "whisper-tiny",
        apiKey: "sk-legacy",
        micDeviceId: "device-9",
      }),
    );

  it("attempts the migration on mount when legacy prefs exist and the server is empty", async () => {
    seedLegacy();
    const fetchServer = vi.fn().mockResolvedValue({ endpoint: "" });
    const push = vi.fn().mockResolvedValue(true);

    const migrated = await ensureLegacySpeechMigrated(fetchServer, push);

    expect(fetchServer).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledWith({
      endpoint: "http://127.0.0.1:8000/v1",
      model: "whisper-tiny",
      apiKey: "sk-legacy",
    });
    expect(migrated?.endpoint).toBe("http://127.0.0.1:8000/v1");
    // The plaintext key no longer lingers locally; the device pref stays.
    expect(readLegacySpeechPrefs()).toBe(null);
    expect(loadSpeechPrefs().micDeviceId).toBe("device-9");
  });

  it("does ZERO server round-trips on the fresh-install path (nothing local)", async () => {
    const fetchServer = vi.fn();
    const push = vi.fn();

    expect(await ensureLegacySpeechMigrated(fetchServer, push)).toBe(null);
    expect(fetchServer).not.toHaveBeenCalled();
    expect(push).not.toHaveBeenCalled();
  });

  it("runs at most once per session — a second call does no redundant RPCs", async () => {
    seedLegacy();
    const fetchServer = vi.fn().mockResolvedValue({ endpoint: "" });
    const push = vi.fn().mockResolvedValue(true);

    await ensureLegacySpeechMigrated(fetchServer, push);
    // Re-seed to prove the guard (not just the cleared localStorage) blocks it.
    seedLegacy();
    const again = await ensureLegacySpeechMigrated(fetchServer, push);

    expect(again).toBe(null);
    expect(fetchServer).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledTimes(1);
  });

  it("retries on a later mount when the server read fails", async () => {
    seedLegacy();
    const failing = vi.fn().mockResolvedValue(null);
    const push = vi.fn().mockResolvedValue(true);

    expect(await ensureLegacySpeechMigrated(failing, push)).toBe(null);
    expect(push).not.toHaveBeenCalled();

    // The guard was released, so the next mount can still migrate.
    const ok = vi.fn().mockResolvedValue({ endpoint: "" });
    const migrated = await ensureLegacySpeechMigrated(ok, push);
    expect(migrated?.endpoint).toBe("http://127.0.0.1:8000/v1");
    expect(push).toHaveBeenCalledTimes(1);
  });
});
