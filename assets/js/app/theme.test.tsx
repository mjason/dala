import React from "react";
import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  getThemePreference,
  setThemePreference,
  ThemeProvider,
  useTheme,
} from "./theme";

type MediaQueryStub = MediaQueryList & {
  setMatches: (matches: boolean) => void;
};

function stubColorScheme(dark: boolean): MediaQueryStub {
  let matches = dark;
  const listeners = new Set<(event: MediaQueryListEvent) => void>();
  const media = {
    get matches() {
      return matches;
    },
    media: "(prefers-color-scheme: dark)",
    onchange: null,
    addEventListener: (_type: string, listener: (event: MediaQueryListEvent) => void) =>
      listeners.add(listener),
    removeEventListener: (_type: string, listener: (event: MediaQueryListEvent) => void) =>
      listeners.delete(listener),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(),
    setMatches(next: boolean) {
      matches = next;
      const event = { matches: next, media: this.media } as MediaQueryListEvent;
      listeners.forEach((listener) => listener(event));
    },
  } as MediaQueryStub;
  vi.stubGlobal("matchMedia", vi.fn().mockReturnValue(media));
  return media;
}

beforeEach(() => {
  localStorage.clear();
  document.documentElement.removeAttribute("data-theme");
  document.documentElement.removeAttribute("data-theme-source");
  document.documentElement.removeAttribute("data-theme-preference");
  stubColorScheme(false);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  Reflect.deleteProperty(window, "dala");
});

describe("theme preference", () => {
  it("defaults invalid or missing preferences to system", () => {
    expect(getThemePreference()).toBe("system");
    localStorage.setItem("phx:theme", "sepia");
    expect(getThemePreference()).toBe("system");
  });

  it("persists explicit themes and represents system by removing the key", () => {
    setThemePreference("light");
    expect(localStorage.getItem("phx:theme")).toBe("light");
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(document.documentElement.dataset.themeSource).toBe("user");

    setThemePreference("system");
    expect(localStorage.getItem("phx:theme")).toBeNull();
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(document.documentElement.dataset.themeSource).toBe("system");
  });
});

describe("ThemeProvider", () => {
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <ThemeProvider>{children}</ThemeProvider>
  );

  it("resolves system theme and follows operating-system changes", () => {
    const media = stubColorScheme(false);
    const { result } = renderHook(useTheme, { wrapper });

    expect(result.current.preference).toBe("system");
    expect(result.current.resolvedTheme).toBe("light");

    act(() => media.setMatches(true));
    expect(result.current.resolvedTheme).toBe("dark");
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  it("does not follow operating-system changes with an explicit preference", () => {
    const media = stubColorScheme(false);
    const { result } = renderHook(useTheme, { wrapper });

    act(() => result.current.setPreference("light"));
    act(() => media.setMatches(true));

    expect(result.current.preference).toBe("light");
    expect(result.current.resolvedTheme).toBe("light");
  });

  it("synchronizes preference changes from another tab", () => {
    const { result } = renderHook(useTheme, { wrapper });
    localStorage.setItem("phx:theme", "dark");

    act(() => window.dispatchEvent(new StorageEvent("storage", { key: "phx:theme" })));

    expect(result.current.preference).toBe("dark");
    expect(result.current.resolvedTheme).toBe("dark");
  });

  it("keeps the desktop preference when browser storage is unavailable", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    const invoke = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(window, "dala", {
      configurable: true,
      value: { getTheme: () => "dark", invoke },
    });

    const { result } = renderHook(useTheme, { wrapper });

    expect(result.current.preference).toBe("dark");
    expect(result.current.resolvedTheme).toBe("dark");
    expect(document.documentElement.dataset.themePreference).toBe("dark");

    act(() =>
      (matchMedia("(prefers-color-scheme: dark)") as MediaQueryStub).setMatches(true),
    );
    expect(result.current.preference).toBe("dark");
    expect(invoke).not.toHaveBeenCalledWith("set_theme", { theme: "system" });
  });

  it("reconciles desktop changes through the external theme store", () => {
    let desktopTheme = "light";
    const listeners = new Set<() => void>();
    Object.defineProperty(window, "dala", {
      configurable: true,
      value: {
        getTheme: () => desktopTheme,
        subscribeTheme: (listener: () => void) => {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
        invoke: vi.fn().mockResolvedValue(undefined),
      },
    });
    const { result } = renderHook(useTheme, { wrapper });

    act(() => {
      desktopTheme = "dark";
      listeners.forEach((listener) => listener());
    });

    expect(result.current.preference).toBe("dark");
    expect(result.current.resolvedTheme).toBe("dark");
    expect(localStorage.getItem("phx:theme")).toBe("dark");
  });
});
