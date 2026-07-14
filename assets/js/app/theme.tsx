import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";

export type ThemePreference = "system" | "light" | "dark";
export type ResolvedTheme = "light" | "dark";

const STORAGE_KEY = "phx:theme";
const MEDIA_QUERY = "(prefers-color-scheme: dark)";
const EVENT = "dala:theme";

function mediaQuery(): MediaQueryList {
  if (typeof window.matchMedia === "function") return window.matchMedia(MEDIA_QUERY);
  return {
    matches: false,
    media: MEDIA_QUERY,
    onchange: null,
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
    addListener: () => undefined,
    removeListener: () => undefined,
    dispatchEvent: () => false,
  };
}

function resolveTheme(preference: ThemePreference): ResolvedTheme {
  return preference === "system" ? (mediaQuery().matches ? "dark" : "light") : preference;
}

export function getThemePreference(): ThemePreference {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored === "light" || stored === "dark" ? stored : "system";
  } catch {
    return "system";
  }
}

function persistThemePreference(preference: ThemePreference) {
  try {
    if (preference === "system") localStorage.removeItem(STORAGE_KEY);
    else localStorage.setItem(STORAGE_KEY, preference);
  } catch {
    // Storage is best effort; the current page still applies the theme.
  }
}

function applyTheme(preference: ThemePreference): ResolvedTheme {
  const resolved = resolveTheme(preference);
  document.documentElement.dataset.theme = resolved;
  document.documentElement.dataset.themeSource = preference === "system" ? "system" : "user";
  document.documentElement.dataset.themePreference = preference;
  return resolved;
}

export function setThemePreference(preference: ThemePreference): ResolvedTheme {
  persistThemePreference(preference);
  const resolved = applyTheme(preference);
  window.dispatchEvent(new CustomEvent(EVENT, { detail: preference }));
  return resolved;
}

type ThemeContextValue = {
  preference: ThemePreference;
  resolvedTheme: ResolvedTheme;
  setPreference: (preference: ThemePreference) => void;
};

const ThemeContext = createContext<ThemeContextValue | null>(null);

type DesktopThemeBridge = {
  invoke: (cmd: string, args: unknown) => Promise<unknown>;
  getTheme?: () => unknown;
  subscribeTheme?: (callback: () => void) => () => void;
};

function themeBridge(): DesktopThemeBridge | undefined {
  return (window as { dala?: DesktopThemeBridge }).dala;
}

function desktopThemeSnapshot(): ThemePreference | null {
  const theme = themeBridge()?.getTheme?.();
  return theme === "system" || theme === "light" || theme === "dark" ? theme : null;
}

function subscribeDesktopTheme(callback: () => void): () => void {
  return themeBridge()?.subscribeTheme?.(callback) ?? (() => undefined);
}

function reportThemeToClient(preference: ThemePreference) {
  const bridge = themeBridge();
  if (bridge) void bridge.invoke("set_theme", { theme: preference }).catch(() => undefined);
}

function initialThemePreference(): ThemePreference {
  const bootstrapTheme = document.documentElement.dataset.themePreference;
  if (bootstrapTheme === "system" || bootstrapTheme === "light" || bootstrapTheme === "dark") {
    return bootstrapTheme;
  }

  return getThemePreference();
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const desktopPreference = useSyncExternalStore(
    subscribeDesktopTheme,
    desktopThemeSnapshot,
    () => null,
  );
  const [preference, setPreferenceState] = useState<ThemePreference>(
    () => desktopPreference ?? initialThemePreference(),
  );
  const [resolvedTheme, setResolvedTheme] = useState<ResolvedTheme>(() => applyTheme(preference));
  const preferenceRef = useRef(preference);

  const sync = useCallback((next: ThemePreference) => {
    preferenceRef.current = next;
    setPreferenceState(next);
    setResolvedTheme(applyTheme(next));
  }, []);

  useLayoutEffect(() => {
    if (desktopPreference && desktopPreference !== preferenceRef.current) {
      persistThemePreference(desktopPreference);
      sync(desktopPreference);
    }
  }, [desktopPreference, sync]);

  useEffect(() => {
    const query = mediaQuery();
    const onSystemChange = () => {
      if (preferenceRef.current === "system") sync("system");
    };
    const onStorage = (event: StorageEvent) => {
      if (event.key === STORAGE_KEY) {
        const next = getThemePreference();
        sync(next);
        reportThemeToClient(next);
      }
    };
    const onLocalChange = (event: Event) => sync((event as CustomEvent<ThemePreference>).detail);

    query.addEventListener("change", onSystemChange);
    window.addEventListener("storage", onStorage);
    window.addEventListener(EVENT, onLocalChange);
    return () => {
      query.removeEventListener("change", onSystemChange);
      window.removeEventListener("storage", onStorage);
      window.removeEventListener(EVENT, onLocalChange);
    };
  }, [sync]);

  const setPreference = useCallback((next: ThemePreference) => {
    setThemePreference(next);
    reportThemeToClient(next);
  }, []);

  const value = useMemo(
    () => ({ preference, resolvedTheme, setPreference }),
    [preference, resolvedTheme, setPreference],
  );

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
  const value = useContext(ThemeContext);
  if (value) return value;

  const preference = getThemePreference();
  return {
    preference,
    resolvedTheme: document.documentElement.dataset.theme === "light" ? "light" : "dark",
    setPreference: setThemePreference,
  };
}
