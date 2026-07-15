import React, { useEffect, useMemo, useRef, useState } from "react";
import { createTheme, updateTheme } from "../../ash_rpc";
import { call } from "../rpc";
import { FieldLabel, TextInput } from "../ui";
import { useI18n } from "../i18n";
import { isTopWindow, Kbd, popWindow, pushWindow } from "../shortcuts";
import { applyCustomTokens, applyTheme, type EffectiveTheme } from "../theme";
import {
  ANSI_KEYS,
  CM_KEYS,
  DIFF_KEYS,
  TERM_BASE_KEYS,
  UI_KEYS,
  type ThemeTokens,
  type TokenKey,
} from "../themeTokens";
import { baseTokenValue } from "../themeBaseTokens";

/** A theme being authored: an existing custom row (`id` set) or a new draft. */
export type ThemeDraft = {
  id?: string;
  name: string;
  base: EffectiveTheme;
  tokens: ThemeTokens;
};

type Props = {
  draft: ThemeDraft;
  /** Cancel/close without saving — the caller restores the prior selection. */
  onClose: () => void;
  /** Saved to the server: the caller selects it, refreshes, and closes. */
  onSaved: (id: string, base: EffectiveTheme, tokens: ThemeTokens) => void;
  onError: (message: string) => void;
};

type Group = { key: "interface" | "terminal" | "ansi"; label: string; keys: readonly TokenKey[] };

const HEX6 = /^#[0-9a-fA-F]{6}$/;
const HEX3 = /^#[0-9a-fA-F]{3}$/;

/** Best-effort `#rrggbb` for the native colour swatch (rgba tokens show solid). */
function toHexColor(value: string): string {
  const v = value.trim();
  if (HEX6.test(v)) return v.toLowerCase();
  if (HEX3.test(v)) return `#${v[1]}${v[1]}${v[2]}${v[2]}${v[3]}${v[3]}`.toLowerCase();
  const m = v.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i);
  if (m) {
    const hex = (n: string) => Math.min(255, Number(n)).toString(16).padStart(2, "0");
    return `#${hex(m[1])}${hex(m[2])}${hex(m[3])}`;
  }
  return "#000000";
}

export default function ThemeEditor({ draft, onClose, onSaved, onError }: Props) {
  const { t } = useI18n();
  const [editingId, setEditingId] = useState<string | undefined>(draft.id);
  const [name, setName] = useState(draft.name);
  const [base, setBase] = useState<EffectiveTheme>(draft.base);
  const [tokens, setTokens] = useState<ThemeTokens>(draft.tokens);
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState({ interface: true, terminal: true, ansi: false });

  const groups: Group[] = useMemo(
    () => [
      { key: "interface", label: t("themeGroupInterface"), keys: [...UI_KEYS, ...DIFF_KEYS, ...CM_KEYS] },
      { key: "terminal", label: t("themeGroupTerminal"), keys: TERM_BASE_KEYS },
      { key: "ansi", label: t("themeGroupAnsi"), keys: ANSI_KEYS },
    ],
    [t],
  );

  // Live preview: paint the whole app with the current draft on every edit,
  // WITHOUT persisting. Cancel restores the prior selection via applyTheme().
  useEffect(() => {
    applyCustomTokens(tokens, base);
  }, [tokens, base]);

  const setToken = (key: TokenKey, value: string) => {
    setTokens((prev) => {
      const next = { ...prev };
      if (value.trim() === "") delete next[key];
      else next[key] = value;
      return next;
    });
  };
  const resetToken = (key: TokenKey) => {
    setTokens((prev) => {
      if (prev[key] === undefined) return prev;
      const next = { ...prev };
      delete next[key];
      return next;
    });
  };

  // Fork the current draft into a fresh, unsaved copy (create on save).
  const duplicate = () => {
    setEditingId(undefined);
    setName((n) => `${n}${t("themeCopySuffix")}`);
  };

  const save = async () => {
    const trimmed = name.trim();
    if (!trimmed) {
      onError(t("themeNameRequired"));
      return;
    }
    setBusy(true);
    const result = editingId
      ? await call<{ id: string }>(updateTheme, {
          identity: editingId,
          input: { name: trimmed, base, tokens },
          fields: ["id"],
        })
      : await call<{ id: string }>(createTheme, {
          input: { name: trimmed, base, tokens },
          fields: ["id"],
        });
    setBusy(false);
    if (result.ok) onSaved(result.data.id, base, tokens);
    else onError(result.error);
  };

  const cancel = () => {
    applyTheme(); // restore the previously-selected theme (drop the preview)
    onClose();
  };

  // Join the window stack so Esc closes the editor first (above the modal).
  const handlersRef = useRef({ cancel });
  handlersRef.current = { cancel };
  useEffect(() => {
    const token = pushWindow();
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !e.defaultPrevented && isTopWindow(token)) {
        e.preventDefault();
        handlersRef.current.cancel();
      }
    };
    window.addEventListener("keydown", handler);
    return () => {
      window.removeEventListener("keydown", handler);
      popWindow(token);
    };
  }, []);

  const baseOptions: { value: EffectiveTheme; label: string }[] = [
    { value: "light", label: t("themeLight") },
    { value: "dark", label: t("themeDark") },
  ];

  return (
    <div
      className="fixed inset-0 z-50 grid place-items-center overflow-hidden bg-black/60 p-4 backdrop-blur-[2px] sm:p-6"
      onClick={cancel}
    >
      <div
        id="theme-editor"
        className="flex max-h-[calc(var(--vvh,100dvh)-2rem)] w-full min-w-0 max-w-lg flex-col animate-[dala-modal-in_150ms_ease-out] rounded-xl border border-line bg-bg1 shadow-2xl shadow-black/50 sm:max-h-[calc(var(--vvh,100dvh)-3rem)]"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex shrink-0 items-center gap-3 px-5 pt-4 pb-3">
          <span className="text-[15px] font-medium text-fg">{t("themeEditorTitle")}</span>
          <div className="flex-1" />
          <button
            id="duplicate-theme-button"
            onClick={duplicate}
            className="rounded-md border border-line px-2.5 py-1 text-xs text-fg-muted transition-colors hover:border-mint/60 hover:text-mint"
          >
            {t("themeDuplicate")}
          </button>
        </header>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4">
          <label className="block space-y-1.5">
            <FieldLabel>{t("name")}</FieldLabel>
            <TextInput
              id="theme-name-input"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="text-[15px]"
            />
          </label>

          <div className="space-y-1.5">
            <FieldLabel>{t("themeBaseLabel")}</FieldLabel>
            <div
              id="theme-base-control"
              className="grid grid-cols-2 gap-0.5 rounded-lg border border-line bg-bg2 p-0.5"
            >
              {baseOptions.map(({ value, label }) => (
                <button
                  key={value}
                  data-theme-base={value}
                  aria-pressed={base === value}
                  onClick={() => setBase(value)}
                  className={`whitespace-nowrap rounded-md px-2.5 py-1 text-xs transition-colors ${
                    base === value
                      ? "bg-bg0 font-medium text-mint shadow-sm"
                      : "text-fg-muted hover:text-fg"
                  }`}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>

          {groups.map((group) => (
            <div key={group.key} className="rounded-lg border border-line/70">
              <button
                type="button"
                data-theme-group={group.key}
                aria-expanded={open[group.key]}
                onClick={() => setOpen((o) => ({ ...o, [group.key]: !o[group.key] }))}
                className="flex w-full items-center justify-between gap-2 px-3 py-2 text-[13px] font-medium text-fg transition-colors hover:bg-bg2/40"
              >
                <span>{group.label}</span>
                <svg
                  viewBox="0 0 16 16"
                  className={`h-3.5 w-3.5 text-fg-muted transition-transform ${
                    open[group.key] ? "rotate-90" : ""
                  }`}
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.5"
                >
                  <path d="m6 4 4 4-4 4" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              </button>
              {open[group.key] && (
                <div className="divide-y divide-line/60 border-t border-line/70">
                  {group.keys.map((key) => {
                    const overridden = tokens[key] !== undefined;
                    const value = tokens[key] ?? "";
                    const placeholder = baseTokenValue(base, key);
                    return (
                      <div
                        key={key}
                        data-token={key}
                        className="flex items-center gap-2.5 px-3 py-1.5"
                      >
                        <input
                          type="color"
                          id={`theme-color-${key}`}
                          aria-label={key}
                          value={toHexColor(value || placeholder)}
                          onChange={(e) => setToken(key, e.target.value)}
                          className="h-6 w-6 shrink-0 cursor-pointer rounded border border-line bg-transparent"
                        />
                        <span className="w-0 flex-1 truncate font-mono text-[11px] text-fg-muted">
                          {key}
                        </span>
                        <div className="w-28 shrink-0">
                          <TextInput
                            id={`theme-hex-${key}`}
                            aria-label={key}
                            value={value}
                            placeholder={placeholder}
                            spellCheck={false}
                            onChange={(e) => setToken(key, e.target.value)}
                            className="px-2 py-1 text-[11px]"
                          />
                        </div>
                        <button
                          type="button"
                          data-reset-token={key}
                          onClick={() => resetToken(key)}
                          disabled={!overridden}
                          className="shrink-0 rounded px-1.5 py-1 text-[11px] text-fg-muted transition-colors hover:text-fg disabled:opacity-30"
                          title={t("themeResetToken")}
                        >
                          {t("themeResetToken")}
                        </button>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          ))}
        </div>

        <footer className="flex shrink-0 items-center justify-end gap-2 border-t border-line px-5 py-3">
          <button
            onClick={cancel}
            className="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-[13px] text-fg-muted transition-colors hover:text-fg"
          >
            {t("cancel")} <Kbd>Esc</Kbd>
          </button>
          <button
            id="save-theme-button"
            onClick={() => void save()}
            disabled={busy}
            className="inline-flex items-center gap-1.5 rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-bg0 transition-all hover:brightness-110 active:scale-[0.98] disabled:opacity-50"
          >
            {t("save")}
          </button>
        </footer>
      </div>
    </div>
  );
}
