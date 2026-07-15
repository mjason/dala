import React, { useState } from "react";
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
import ThemeEditor, { type ThemeDraft } from "./ThemeEditor";
import ToggleRow from "./ToggleRow";

/**
 * Terminal appearance (font, size, line height, cursor) plus the app-wide
 * theme: the built-in light/dark/system triad and the custom-theme library
 * (chips + the 39-colour editor). Browser-local and global across sessions;
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

  /** The swatch colour for a chip: its bg0 override, else the base default. */
  const chipSwatch = (theme: ThemeSummary) =>
    theme.tokens.bg0 ?? baseTokenValue(theme.base, "bg0");

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
            className="rounded-md border border-mint/50 px-2.5 py-1 text-xs text-mint transition-colors hover:bg-mint/10"
          >
            {t("newTheme")}
          </button>
        </div>
        <div id="theme-library" className="flex flex-wrap gap-1.5">
          {themes.map((theme) => {
            const selected = selectedCustomId === theme.id;
            return (
              <div
                key={theme.id}
                className={`inline-flex items-center gap-1 rounded-lg border p-0.5 transition-colors ${
                  selected ? "border-mint/60 bg-mint/10" : "border-line bg-bg2"
                }`}
              >
                <button
                  data-custom-theme-id={theme.id}
                  aria-pressed={selected}
                  onClick={() => selectCustom(theme)}
                  className="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs text-fg transition-colors hover:text-mint"
                >
                  <span
                    className="h-3 w-3 shrink-0 rounded-full border border-line"
                    style={{ backgroundColor: chipSwatch(theme) }}
                  />
                  {theme.name}
                </button>
                {theme.builtin ? (
                  <button
                    data-fork-theme-id={theme.id}
                    onClick={() => openFork(theme)}
                    title={t("themeFork")}
                    className="rounded px-1 py-0.5 text-[11px] text-fg-muted transition-colors hover:text-mint"
                  >
                    {t("themeFork")}
                  </button>
                ) : (
                  <>
                    <button
                      data-edit-theme-id={theme.id}
                      onClick={() => openEdit(theme)}
                      title={t("themeEdit")}
                      className="rounded px-1 py-0.5 text-[11px] text-fg-muted transition-colors hover:text-mint"
                    >
                      {t("themeEdit")}
                    </button>
                    <button
                      data-delete-theme-id={theme.id}
                      onClick={() => void deleteThemeChip(theme)}
                      title={t("themeDelete")}
                      className={`rounded px-1 py-0.5 text-[11px] transition-colors ${
                        confirmDeleteId === theme.id
                          ? "font-medium text-danger"
                          : "text-fg-muted hover:text-danger"
                      }`}
                    >
                      {confirmDeleteId === theme.id ? t("themeDeleteConfirm") : t("themeDelete")}
                    </button>
                  </>
                )}
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
