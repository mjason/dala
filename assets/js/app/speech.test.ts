import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_SPEECH_PREFS, loadSpeechPrefs, saveSpeechPrefs } from "./speech";

const KEY = "dala:speech-prefs";

beforeEach(() => {
  localStorage.clear();
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

  it("strips unknown fields", () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({ endpoint: "http://x/v1", evil: "payload", legacy: 1 }),
    );
    const prefs = loadSpeechPrefs();
    expect(prefs).toEqual({ ...DEFAULT_SPEECH_PREFS, endpoint: "http://x/v1" });
    expect(Object.keys(prefs).sort()).toEqual(["apiKey", "endpoint", "micDeviceId", "model"]);
  });

  it("falls back per field when a stored value has the wrong type", () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({ endpoint: 5, model: 42, apiKey: {}, micDeviceId: ["x"] }),
    );
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);
  });

  it("treats an empty model as unset but keeps other empty strings", () => {
    localStorage.setItem(KEY, JSON.stringify({ model: "", endpoint: "", apiKey: "" }));
    const prefs = loadSpeechPrefs();
    expect(prefs.model).toBe(DEFAULT_SPEECH_PREFS.model);
    expect(prefs.endpoint).toBe("");
    expect(prefs.apiKey).toBe("");
  });

  it("keeps well-formed stored values", () => {
    const stored = {
      endpoint: "http://127.0.0.1:8000/v1",
      model: "whisper-tiny",
      apiKey: "sk-secret",
      micDeviceId: "device-42",
    };
    localStorage.setItem(KEY, JSON.stringify(stored));
    expect(loadSpeechPrefs()).toEqual(stored);
  });

  it("returns the defaults when storage itself throws", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage unavailable");
    });
    expect(loadSpeechPrefs()).toEqual(DEFAULT_SPEECH_PREFS);
  });
});

describe("saveSpeechPrefs", () => {
  it("merges a partial patch over the stored prefs and persists it", () => {
    saveSpeechPrefs({ endpoint: "http://x/v1" });
    const merged = saveSpeechPrefs({ model: "whisper-tiny" });

    expect(merged).toEqual({
      ...DEFAULT_SPEECH_PREFS,
      endpoint: "http://x/v1",
      model: "whisper-tiny",
    });
    // round-trip through storage
    expect(loadSpeechPrefs()).toEqual(merged);
  });

  it("overwrites a previously saved field", () => {
    saveSpeechPrefs({ micDeviceId: "old" });
    saveSpeechPrefs({ micDeviceId: "new" });
    expect(loadSpeechPrefs().micDeviceId).toBe("new");
  });

  it("still returns the merged prefs when storage writes fail", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota exceeded");
    });
    const merged = saveSpeechPrefs({ apiKey: "sk-1" });
    expect(merged.apiKey).toBe("sk-1");
    expect(merged.model).toBe(DEFAULT_SPEECH_PREFS.model);
  });
});
