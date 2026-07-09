import React, { createContext, useCallback, useContext, useMemo, useState } from "react";
import { de, en, es, fr, ja, ko, pt, ru, zhCN, zhTW } from "./locales";
import type { Messages } from "./locales";

export const DICTIONARIES = {
  en,
  "zh-CN": zhCN,
  "zh-TW": zhTW,
  ja,
  ko,
  es,
  fr,
  de,
  ru,
  pt,
} as const;

export type Locale = keyof typeof DICTIONARIES;
export type MessageKey = keyof Messages;

/** Native names, shown in the language switcher. */
export const LOCALE_NAMES: Record<Locale, string> = {
  en: "English",
  "zh-CN": "简体中文",
  "zh-TW": "繁體中文",
  ja: "日本語",
  ko: "한국어",
  es: "Español",
  fr: "Français",
  de: "Deutsch",
  ru: "Русский",
  pt: "Português",
};

const STORAGE_KEY = "dala:locale";

/** Maps a browser language list to the best supported locale. */
export function detectLocale(languages: readonly string[]): Locale {
  for (const raw of languages) {
    const lang = raw.toLowerCase();

    // Chinese needs script-aware mapping, not just prefix matching.
    if (lang.startsWith("zh")) {
      if (/^zh(-hant|-tw|-hk|-mo)/.test(lang)) return "zh-TW";
      return "zh-CN";
    }

    const exact = (Object.keys(DICTIONARIES) as Locale[]).find(
      (locale) => locale.toLowerCase() === lang,
    );
    if (exact) return exact;

    const primary = lang.split("-")[0];
    const byPrefix = (Object.keys(DICTIONARIES) as Locale[]).find(
      (locale) => locale.toLowerCase().split("-")[0] === primary,
    );
    if (byPrefix) return byPrefix;
  }

  return "en";
}

export function getInitialLocale(): Locale {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored && stored in DICTIONARIES) return stored as Locale;
  } catch {
    // storage unavailable (e.g. privacy mode) — fall through to detection
  }
  return detectLocale(navigator.languages ?? [navigator.language]);
}

export function translate(
  locale: Locale,
  key: MessageKey,
  params?: Record<string, string | number>,
): string {
  let message: string = DICTIONARIES[locale][key] ?? DICTIONARIES.en[key];
  if (params) {
    for (const [name, value] of Object.entries(params)) {
      message = message.replaceAll(`{${name}}`, String(value));
    }
  }
  return message;
}

type I18n = {
  locale: Locale;
  t: (key: MessageKey, params?: Record<string, string | number>) => string;
  setLocale: (locale: Locale) => void;
};

const I18nContext = createContext<I18n>({
  locale: "en",
  t: (key, params) => translate("en", key, params),
  setLocale: () => undefined,
});

export function I18nProvider({ children }: { children: React.ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(getInitialLocale);

  const setLocale = useCallback((next: Locale) => {
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // best effort
    }
    setLocaleState(next);
  }, []);

  const value = useMemo<I18n>(
    () => ({
      locale,
      t: (key, params) => translate(locale, key, params),
      setLocale,
    }),
    [locale, setLocale],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18n {
  return useContext(I18nContext);
}
