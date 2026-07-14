import React, { useEffect, useState } from "react";
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
import ToggleRow from "./ToggleRow";
import { useTheme } from "../theme";

/**
 * Terminal appearance (font, size, line height, cursor). Browser-local and
 * global across sessions; every change persists and applies to open
 * terminals immediately, so there is no save step.
 */
export default function AppearanceSection() {
  const { t } = useI18n();
  const { preference, setPreference } = useTheme();
  const [prefs, setPrefs] = useState<TermPrefs>(loadPrefs);
  // Live terminal geometry — the ground truth for clipping bug reports:
  // wrapper (clipping box) / container (fit target) / screen (canvas),
  // devicePixelRatio (includes browser zoom).
  const [geometry, setGeometry] = useState("");
  useEffect(() => {
    const read = () => {
      const container = document.querySelector(".xterm")?.parentElement;
      const wrapper = container?.parentElement?.parentElement;
      const screen = document.querySelector(".xterm-screen");
      if (!container || !screen) return;
      setGeometry(
        `wrap ${wrapper?.clientHeight ?? "?"} · box ${container.clientHeight} · canvas ${screen.clientHeight} · dpr ${window.devicePixelRatio}`,
      );
    };
    read();
    const timer = window.setInterval(read, 1000);
    return () => window.clearInterval(timer);
  }, []);

  const apply = (patch: Partial<TermPrefs>) => setPrefs(savePrefs(patch));

  const cursorStyles: { value: CursorStyle; label: string }[] = [
    { value: "bar", label: t("cursorBar") },
    { value: "block", label: t("cursorBlock") },
    { value: "underline", label: t("cursorUnderline") },
  ];

  return (
    <div className="space-y-4">
      <div id="theme-selector" className="space-y-1.5">
        <FieldLabel>{t("theme")}</FieldLabel>
        <div className="grid grid-cols-3 gap-0.5 rounded-lg border border-line bg-bg0 p-0.5">
          {(["system", "light", "dark"] as const).map((theme) => (
            <button
              key={theme}
              id={`theme-${theme}-button`}
              aria-pressed={preference === theme}
              onClick={() => setPreference(theme)}
              className={`rounded-md px-2.5 py-1.5 text-xs transition-colors ${
                preference === theme
                  ? "bg-bg2 font-medium text-fg shadow-sm"
                  : "text-fg-muted hover:text-fg"
              }`}
            >
              {t(theme === "system" ? "themeSystem" : theme === "light" ? "themeLight" : "themeDark")}
            </button>
          ))}
        </div>
      </div>

      <div className="flex items-start justify-between gap-3">
        <span className="text-xs leading-5 text-fg-muted/80">
          {t("appearanceScope")}
          {typeof document !== "undefined" && document.documentElement.dataset.termRenderer && (
            <span className="ml-2 font-mono text-[10px] uppercase text-fg-muted/60">
              {t("renderer")}: {document.documentElement.dataset.termRenderer}
            </span>
          )}
          {geometry && (
            <span id="terminal-geometry" className="ml-2 font-mono text-[10px] text-fg-muted/60">
              {geometry}
            </span>
          )}
        </span>
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
        <div className="grid grid-cols-3 gap-0.5 rounded-lg border border-line bg-bg0 p-0.5">
          {cursorStyles.map(({ value, label }) => (
            <button
              key={value}
              data-cursor-style={value}
              onClick={() => apply({ cursorStyle: value })}
              className={`whitespace-nowrap rounded-md px-2.5 py-1 text-xs transition-colors ${
                prefs.cursorStyle === value
                  ? "bg-bg2 font-medium text-mint shadow-sm"
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
    </div>
  );
}
