import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { notificationsEnabled, setNotificationsEnabled } from "./notifyPrefs";

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("notificationsEnabled", () => {
  it("defaults to on when nothing is stored", () => {
    expect(notificationsEnabled()).toBe(true);
  });

  it('is off only for the literal "off" value', () => {
    localStorage.setItem("dala:notifications", "off");
    expect(notificationsEnabled()).toBe(false);
  });

  it("treats any other stored value as on", () => {
    localStorage.setItem("dala:notifications", "banana");
    expect(notificationsEnabled()).toBe(true);

    localStorage.setItem("dala:notifications", "");
    expect(notificationsEnabled()).toBe(true);
  });

  it("defaults to on when storage throws", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage unavailable");
    });
    expect(notificationsEnabled()).toBe(true);
  });
});

describe("setNotificationsEnabled", () => {
  it("round-trips off and back on", () => {
    setNotificationsEnabled(false);
    expect(notificationsEnabled()).toBe(false);

    setNotificationsEnabled(true);
    expect(notificationsEnabled()).toBe(true);
  });

  it("swallows storage failures", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota exceeded");
    });
    expect(() => setNotificationsEnabled(false)).not.toThrow();
  });
});
