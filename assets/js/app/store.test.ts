import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createStore } from "./store";

type Prefs = { name: string; count: number };

const KEY = "test:prefs";
const DEFAULTS: Prefs = { name: "anon", count: 1 };

const plain = () => createStore<Prefs>(KEY, DEFAULTS);

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("createStore load", () => {
  it("returns the defaults when nothing is stored", () => {
    expect(plain().load()).toEqual(DEFAULTS);
  });

  it("returns the defaults for garbage JSON", () => {
    localStorage.setItem(KEY, "{not json at all");
    expect(plain().load()).toEqual(DEFAULTS);
  });

  it("returns the defaults for JSON that is not an object", () => {
    localStorage.setItem(KEY, "null");
    expect(plain().load()).toEqual(DEFAULTS);

    localStorage.setItem(KEY, '"just a string"');
    expect(plain().load()).toEqual(DEFAULTS);

    localStorage.setItem(KEY, "[1,2]");
    expect(plain().load()).toEqual(DEFAULTS);
  });

  it("merges stored values over the defaults and strips unknown fields", () => {
    localStorage.setItem(KEY, JSON.stringify({ name: "mj", evil: "payload" }));
    const loaded = plain().load();
    expect(loaded).toEqual({ name: "mj", count: 1 });
    expect(Object.keys(loaded).sort()).toEqual(["count", "name"]);
  });

  it("returns the defaults when storage itself throws", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage unavailable");
    });
    expect(plain().load()).toEqual(DEFAULTS);
  });

  it("runs the stored value through normalize when given", () => {
    const store = createStore<Prefs>(KEY, DEFAULTS, (raw) => ({
      name: typeof raw.name === "string" ? raw.name : DEFAULTS.name,
      count: typeof raw.count === "number" ? raw.count : DEFAULTS.count,
    }));
    localStorage.setItem(KEY, JSON.stringify({ name: 42, count: "oops" }));
    expect(store.load()).toEqual(DEFAULTS);
  });

  it("returns a fresh copy of the defaults (no shared mutable state)", () => {
    const store = plain();
    const first = store.load();
    first.name = "mutated";
    expect(store.load().name).toBe("anon");
  });
});

describe("createStore save", () => {
  it("merges a partial patch over the stored value and persists it", () => {
    const store = plain();
    store.save({ name: "mj" });
    const merged = store.save({ count: 7 });

    expect(merged).toEqual({ name: "mj", count: 7 });
    // round-trip through storage
    expect(store.load()).toEqual(merged);
  });

  it("overwrites a previously saved field", () => {
    const store = plain();
    store.save({ name: "old" });
    store.save({ name: "new" });
    expect(store.load().name).toBe("new");
  });

  it("still returns the merged value when storage writes fail", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota exceeded");
    });
    const merged = plain().save({ count: 5 });
    expect(merged).toEqual({ name: "anon", count: 5 });
  });

  it("normalizes the merged value before persisting", () => {
    const store = createStore<Prefs>(KEY, DEFAULTS, (raw) => ({
      name: typeof raw.name === "string" ? raw.name : DEFAULTS.name,
      count: Math.min(Number(raw.count) || DEFAULTS.count, 10),
    }));
    const merged = store.save({ count: 99 });
    expect(merged.count).toBe(10);
    expect(store.load().count).toBe(10);
  });
});

describe("createStore event broadcast", () => {
  it("dispatches a CustomEvent with the merged value after save", () => {
    const store = createStore<Prefs>(KEY, DEFAULTS, undefined, { event: "test:prefs-event" });
    const seen = vi.fn();
    const handler = (e: Event) => seen((e as CustomEvent<Prefs>).detail);
    window.addEventListener("test:prefs-event", handler);
    try {
      store.save({ count: 3 });
      expect(seen).toHaveBeenCalledTimes(1);
      expect(seen).toHaveBeenCalledWith({ name: "anon", count: 3 });
    } finally {
      window.removeEventListener("test:prefs-event", handler);
    }
  });

  it("still dispatches when the storage write fails", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota exceeded");
    });
    const store = createStore<Prefs>(KEY, DEFAULTS, undefined, { event: "test:prefs-event" });
    const seen = vi.fn();
    window.addEventListener("test:prefs-event", seen);
    try {
      store.save({ count: 2 });
      expect(seen).toHaveBeenCalledTimes(1);
    } finally {
      window.removeEventListener("test:prefs-event", seen);
    }
  });

  it("does not dispatch anything without the event option", () => {
    const seen = vi.fn();
    window.addEventListener("test:prefs-event", seen);
    try {
      plain().save({ count: 3 });
      expect(seen).not.toHaveBeenCalled();
    } finally {
      window.removeEventListener("test:prefs-event", seen);
    }
  });
});
