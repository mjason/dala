import React, { useState } from "react";
import { Check, Copy, Pencil, Plus, Trash2 } from "lucide-react";
import { deleteTheme } from "../../ash_rpc";
import { call } from "../rpc";
import { FieldLabel, TextInput, ValueChip } from "../ui";
import { useI18n } from "../i18n";
import {
  defaultFontSize,
  FONT_SIZE_RANGE,
  LINE_HEIGHT_RANGE,
  SCROLL_SENSITIVITY_RANGE,
  loadPrefs,
  resetPrefs,
  savePrefs,
} from "../termPrefs";
import type { CursorStyle, TermPrefs } from "../termPrefs";
import {
  applyTheme,
  cacheCustomTheme,
  effectiveTheme,
  loadThemeChoice,
  saveThemeChoice,
  type EffectiveTheme,
  type ThemeSetting,
} from "../theme";
import { useThemeLibrary } from "../hooks/useThemeLibrary";
import type { ThemeSummary } from "../themeLibrary";
import { baseTokenValue } from "../themeBaseTokens";
import type { TokenKey } from "../themeTokens";
import ThemeEditor, { type ThemeDraft } from "./ThemeEditor";
import ToggleRow from "./ToggleRow";

/**
 * Terminal appearance (font, size, line height, cursor) plus the app-wide
 * theme: the built-in light/dark/system triad and the custom-theme library
 * (chips + the 46-colour editor). Browser-local and global across sessions;
 * every change persists and applies immediately, so there is no save step.
 */
export default function AppearanceSection({
  onError,
}: {
  onError: (message: string) => void;
}) {
  const { t } = useI18n();
  const [prefs, setPrefs] = useState<TermPrefs>(loadPrefs);

  const apply = (patch: Partial<TermPrefs>) => setPrefs(savePrefs(patch));

  // App-wide theme (shell + terminal). Browser-local; the built-in triad
  // resolves against the OS in "system" mode, a custom choice pins its base.
  const [choice, setChoice] = useState(loadThemeChoice);
  const selectedCustomId = choice.setting === "custom" ? choice.customId : null;

  const { themes, reload } = useThemeLibrary(onError);
  const [editor, setEditor] = useState<ThemeDraft | null>(null);
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);

  // Built-in triad: clears any remembered customId so it leaves custom mode.
  const chooseTheme = (value: ThemeSetting) => {
    saveThemeChoice(value, null);
    applyTheme();
    setChoice({ setting: value, customId: null });
    setConfirmDeleteId(null);
  };

  const selectCustom = (theme: ThemeSummary) => {
    saveThemeChoice("custom", theme.id);
    applyTheme();
    setChoice({ setting: "custom", customId: theme.id });
    setConfirmDeleteId(null);
  };

  const openNew = () =>
    setEditor({ name: "", base: effectiveTheme(), tokens: {} });

  const openEdit = (theme: ThemeSummary) =>
    setEditor({ id: theme.id, name: theme.name, base: theme.base, tokens: { ...theme.tokens } });

  const openFork = (theme: ThemeSummary) =>
    setEditor({
      name: `${theme.name}${t("themeCopySuffix")}`,
      base: theme.base,
      tokens: { ...theme.tokens },
    });

  const handleSaved = (id: string, base: EffectiveTheme, tokens: Record<string, string>) => {
    // Prime the boot cache so selecting paints instantly (no fallback flash).
    cacheCustomTheme(id, base, tokens);
    saveThemeChoice("custom", id);
    applyTheme();
    setChoice({ setting: "custom", customId: id });
    void reload();
    setEditor(null);
  };

  const deleteThemeChip = async (theme: ThemeSummary) => {
    if (confirmDeleteId !== theme.id) {
      setConfirmDeleteId(theme.id);
      return;
    }
    setConfirmDeleteId(null);
    const result = await call<unknown>(deleteTheme, { identity: theme.id });
    if (!result.ok) {
      onError(result.error);
      return;
    }
    // If we deleted the ACTIVE custom theme, actually repaint by reusing the
    // built-in "system" path (persist + applyTheme, which clears the custom
    // overrides and re-colours shell + terminal) — not just a local state flip,
    // which would leave the app painted with the now-deleted theme until reload.
    if (selectedCustomId === theme.id) chooseTheme("system");
    void reload();
  };

  const themeOptions: { value: ThemeSetting; label: string }[] = [
    { value: "system", label: t("themeSystem") },
    { value: "light", label: t("themeLight") },
    { value: "dark", label: t("themeDark") },
  ];

  const cursorStyles: { value: CursorStyle; label: string }[] = [
    { value: "bar", label: t("cursorBar") },
    { value: "block", label: t("cursorBlock") },
    { value: "underline", label: t("cursorUnderline") },
  ];

  const themeColor = (theme: ThemeSummary, key: TokenKey) =>
    theme.tokens[key] ?? baseTokenValue(theme.base, key);

  const ansiPreview: TokenKey[] = [
    "ansiRed",
    "ansiGreen",
    "ansiYellow",
    "ansiBlue",
    "ansiMagenta",
    "ansiCyan",
    "ansiWhite",
    "ansiBrightBlack",
  ];
  const gitPreview: { label: string; key: TokenKey }[] = [
    { label: "A", key: "gitAdded" },
    { label: "M", key: "gitModified" },
    { label: "D", key: "gitDeleted" },
    { label: "R", key: "gitRenamed" },
    { label: "U", key: "gitUntracked" },
    { label: "!", key: "gitConflict" },
    { label: "I", key: "gitIgnored" },
  ];

  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-3">
        <span className="text-xs leading-5 text-fg-muted/80">{t("appearanceScope")}</span>
        <div className="flex shrink-0 items-baseline gap-3">
          <button
            id="layout-reset-button"
            onClick={() => window.dispatchEvent(new CustomEvent("dala:reset-layout"))}
            className="text-xs text-fg-muted underline decoration-line underline-offset-2 transition-colors hover:text-fg"
          >
            {t("resetLayout")}
          </button>
          <button
            id="appearance-reset-button"
            onClick={() => setPrefs(resetPrefs())}
            className="text-xs text-fg-muted underline decoration-line underline-offset-2 transition-colors hover:text-fg"
          >
            {t("resetDefaults")}
          </button>
        </div>
      </div>

      <div className="space-y-1.5">
        <FieldLabel>{t("themeLabel")}</FieldLabel>
        <div
          id="theme-setting-control"
          className="grid grid-cols-3 gap-0.5 rounded-lg border border-line bg-bg2 p-0.5"
        >
          {themeOptions.map(({ value, label }) => (
            <button
              key={value}
              data-theme-setting={value}
              aria-pressed={choice.setting === value}
              onClick={() => chooseTheme(value)}
              className={`whitespace-nowrap rounded-md px-2.5 py-1 text-xs transition-colors ${
                choice.setting === value
                  ? "bg-bg0 font-medium text-mint shadow-sm"
                  : "text-fg-muted hover:text-fg"
              }`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <div className="space-y-1.5">
        <div className="flex items-center justify-between gap-2">
          <FieldLabel>{t("themeLibrary")}</FieldLabel>
          <button
            id="new-theme-button"
            onClick={openNew}
            className="inline-flex h-7 items-center gap-1.5 rounded-md border border-mint/50 px-2.5 text-xs text-mint transition-colors hover:bg-mint/10"
          >
            <Plus className="h-3.5 w-3.5" aria-hidden />
            {t("newTheme")}
          </button>
        </div>
        <div id="theme-library" className="grid grid-cols-1 gap-2 sm:grid-cols-2">
          {themes.map((theme) => {
            const selected = selectedCustomId === theme.id;
            const bg0 = themeColor(theme, "bg0");
            const bg1 = themeColor(theme, "bg1");
            const bg2 = themeColor(theme, "bg2");
            const line = themeColor(theme, "line");
            const fg = themeColor(theme, "fg");
            const muted = themeColor(theme, "fgMuted");
            const accent = themeColor(theme, "mint");
            const danger = themeColor(theme, "danger");
            const termBg = themeColor(theme, "termBackground");
            const termFg = themeColor(theme, "termForeground");
            return (
              <div
                key={theme.id}
                className={`min-w-0 overflow-hidden rounded-md border transition-[box-shadow,transform] ${
                  selected ? "ring-1 ring-mint/70" : "hover:-translate-y-px hover:shadow-md"
                }`}
                style={{ backgroundColor: bg1, borderColor: selected ? accent : line }}
              >
                <button
                  data-custom-theme-id={theme.id}
                  aria-pressed={selected}
                  onClick={() => selectCustom(theme)}
                  className="group block w-full px-2.5 pb-2 pt-2 text-left"
                >
                  <span className="flex min-w-0 items-center gap-2">
                    <span className="min-w-0 flex-1 truncate text-xs font-semibold" style={{ color: fg }}>
                      {theme.name}
                    </span>
                    <span className="shrink-0 text-[10px]" style={{ color: muted }}>
                      {theme.base === "dark" ? t("themeDark") : t("themeLight")}
                    </span>
                    {selected && (
                      <span className="grid h-4 w-4 shrink-0 place-items-center rounded-full" style={{ backgroundColor: accent, color: bg0 }}>
                        <Check className="h-3 w-3" aria-hidden />
                      </span>
                    )}
                  </span>

                  <span
                    data-theme-git-preview={theme.id}
                    aria-hidden
                    className="mt-2 flex h-6 items-center justify-between border px-2 font-mono text-[10px]"
                    style={{ backgroundColor: bg0, borderColor: line }}
                  >
                    <span style={{ color: muted }}>src/app.ts</span>
                    <span className="flex items-center gap-2">
                      {gitPreview.map((item) => (
                        <span
                          key={item.key}
                          data-theme-git-swatch={item.key}
                          className="font-semibold"
                          style={{ color: themeColor(theme, item.key) }}
                        >
                          {item.label}
                        </span>
                      ))}
                    </span>
                  </span>

                  <span
                    data-theme-terminal-preview={theme.id}
                    aria-hidden
                    className="mt-2 block overflow-hidden border font-mono"
                    style={{ backgroundColor: termBg, borderColor: line }}
                  >
                    <span className="flex h-4 items-center gap-1 border-b px-1.5" style={{ backgroundColor: bg2, borderColor: line }}>
                      <span className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: danger }} />
                      <span className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: themeColor(theme, "ansiYellow") }} />
                      <span className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: accent }} />
                    </span>
                    <span className="block px-2 pb-1.5 pt-1 text-[9px] leading-4" style={{ color: termFg }}>
                      <span style={{ color: themeColor(theme, "ansiCyan") }}>~</span>{" "}
                      <span style={{ color: accent }}>$</span>{" dala status"}
                      <br />
                      <span style={{ color: muted }}>ready</span>{" "}
                      <span style={{ color: themeColor(theme, "ansiBlue") }}>main</span>
                    </span>
                    <span data-theme-palette={theme.id} className="grid h-2 grid-cols-8">
                      {ansiPreview.map((key) => (
                        <span key={key} data-theme-ansi-swatch style={{ backgroundColor: themeColor(theme, key) }} />
                      ))}
                    </span>
                  </span>
                </button>

                <div className="flex h-7 items-center justify-end gap-0.5 border-t px-1.5" style={{ backgroundColor: bg2, borderColor: line }}>
                  {theme.builtin ? (
                    <button
                      data-fork-theme-id={theme.id}
                      onClick={() => openFork(theme)}
                      title={t("themeFork")}
                      className="grid h-5 w-6 place-items-center rounded text-fg-muted transition-colors hover:bg-bg0/60 hover:text-mint"
                    >
                      <Copy className="h-3 w-3" aria-hidden />
                      <span className="sr-only">{t("themeFork")}</span>
                    </button>
                  ) : (
                    <>
                      <button
                        data-edit-theme-id={theme.id}
                        onClick={() => openEdit(theme)}
                        title={t("themeEdit")}
                        className="grid h-5 w-6 place-items-center rounded text-fg-muted transition-colors hover:bg-bg0/60 hover:text-mint"
                      >
                        <Pencil className="h-3 w-3" aria-hidden />
                        <span className="sr-only">{t("themeEdit")}</span>
                      </button>
                      <button
                        data-delete-theme-id={theme.id}
                        onClick={() => void deleteThemeChip(theme)}
                        title={t("themeDelete")}
                        className={`flex h-5 items-center justify-center rounded px-1.5 text-[10px] transition-colors ${
                          confirmDeleteId === theme.id
                            ? "gap-1 font-medium text-danger"
                            : "w-6 text-fg-muted hover:bg-bg0/60 hover:text-danger"
                        }`}
                      >
                        <Trash2 className="h-3 w-3" aria-hidden />
                        {confirmDeleteId === theme.id && <span>{t("themeDeleteConfirm")}</span>}
                        <span className="sr-only">{t("themeDelete")}</span>
                      </button>
                    </>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <div className="space-y-1.5">
        <FieldLabel>{t("fontSize")}</FieldLabel>
        <div className="flex items-center gap-3">
          <input
            id="font-size-input"
            type="range"
            min={FONT_SIZE_RANGE.min}
            max={FONT_SIZE_RANGE.max}
            value={prefs.fontSize}
            onChange={(e) => apply({ fontSize: Number(e.target.value) })}
            className="flex-1"
          />
          <div className="w-16 shrink-0">
            <TextInput
              type="number"
              min={FONT_SIZE_RANGE.min}
              max={FONT_SIZE_RANGE.max}
              value={prefs.fontSize}
              onChange={(e) => apply({ fontSize: Number(e.target.value) || defaultFontSize() })}
              className="text-right"
            />
          </div>
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <div className="flex items-center justify-between">
            <FieldLabel>{t("lineHeight")}</FieldLabel>
            <ValueChip>{prefs.lineHeight.toFixed(2)}</ValueChip>
          </div>
          <input
            id="line-height-input"
            type="range"
            min={LINE_HEIGHT_RANGE.min}
            max={LINE_HEIGHT_RANGE.max}
            step={0.05}
            value={prefs.lineHeight}
            onChange={(e) => apply({ lineHeight: Number(e.target.value) })}
            className="w-full"
          />
        </div>
        <div className="space-y-1.5">
          <div className="flex items-center justify-between">
            <FieldLabel>{t("scrollSensitivity")}</FieldLabel>
            <ValueChip>{prefs.scrollSensitivity.toFixed(1)}×</ValueChip>
          </div>
          <input
            id="scroll-sensitivity-input"
            type="range"
            min={SCROLL_SENSITIVITY_RANGE.min}
            max={SCROLL_SENSITIVITY_RANGE.max}
            step={0.5}
            value={prefs.scrollSensitivity}
            onChange={(e) => apply({ scrollSensitivity: Number(e.target.value) })}
            className="w-full"
          />
        </div>
      </div>

      <label className="block space-y-1.5">
        <FieldLabel>{t("fontFamily")}</FieldLabel>
        <TextInput
          id="font-family-input"
          value={prefs.fontFamily}
          onChange={(e) => apply({ fontFamily: e.target.value })}
          placeholder="JetBrainsMono NFM"
          spellCheck={false}
        />
        <span className="block text-xs leading-5 text-fg-muted/80">{t("fontFamilyHint")}</span>
      </label>

      <div className="space-y-1.5">
        <FieldLabel>{t("cursorStyleLabel")}</FieldLabel>
        <div className="grid grid-cols-3 gap-0.5 rounded-lg border border-line bg-bg2 p-0.5">
          {cursorStyles.map(({ value, label }) => (
            <button
              key={value}
              data-cursor-style={value}
              onClick={() => apply({ cursorStyle: value })}
              className={`whitespace-nowrap rounded-md px-2.5 py-1 text-xs transition-colors ${
                prefs.cursorStyle === value
                  ? "bg-bg0 font-medium text-mint shadow-sm"
                  : "text-fg-muted hover:text-fg"
              }`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <div className="divide-y divide-line/70 rounded-lg border border-line/70">
        <ToggleRow
          id="cursor-blink-checkbox"
          label={t("cursorBlink")}
          checked={prefs.cursorBlink}
          onChange={(v) => apply({ cursorBlink: v })}
        />
        <ToggleRow
          id="copy-on-select-checkbox"
          label={t("copyOnSelect")}
          checked={prefs.copyOnSelect}
          onChange={(v) => apply({ copyOnSelect: v })}
        />
        <ToggleRow
          id="smooth-scroll-checkbox"
          label={t("smoothScroll")}
          checked={prefs.smoothScroll}
          onChange={(v) => apply({ smoothScroll: v })}
        />
        <ToggleRow
          id="local-echo-checkbox"
          label={t("localEcho")}
          checked={prefs.localEcho}
          onChange={(v) => apply({ localEcho: v })}
        />
      </div>

      {editor && (
        <ThemeEditor
          draft={editor}
          onClose={() => setEditor(null)}
          onSaved={handleSaved}
          onError={onError}
        />
      )}
    </div>
  );
}
