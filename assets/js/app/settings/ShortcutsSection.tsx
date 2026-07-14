import React, { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import { KEY_GUIDE } from "../keyGuide";
import {
  BINDINGS,
  comboFromEvent,
  formatCombo,
  loadBindings,
  onBindingsChange,
  resetBindings,
  saveBinding,
} from "../keybindings";

/**
 * Every shortcut in the app, rebindable: click a combo, press the new keys
 * (Escape cancels). Stored per browser; the desktop client mirrors the
 * menu-bar ones (composer / quick shell / voice) into real accelerators.
 */
export default function ShortcutsSection() {
  const { t } = useI18n();
  const [bindings, setBindings] = useState(loadBindings);
  const [recording, setRecording] = useState<string | null>(null);

  useEffect(() => onBindingsChange(setBindings), []);

  useEffect(() => {
    if (!recording) return;
    const handler = (event: KeyboardEvent) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.key === "Escape") {
        setRecording(null);
        return;
      }
      const combo = comboFromEvent(event);
      if (combo) {
        setBindings(saveBinding(recording, combo));
        setRecording(null);
      }
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [recording]);

  return (
    <div className="space-y-4">
      <p className="text-[12px] leading-relaxed text-fg-muted">{t("shortcutsDesc")}</p>
      <div className="divide-y divide-line/60 rounded-lg border border-line">
        {BINDINGS.map((spec) => {
          const combo = bindings[spec.id];
          const isDefault = combo === spec.default;
          return (
            <div key={spec.id} className="flex items-center gap-2 px-3 py-2">
              <span className="flex-1 truncate text-[13px] text-fg">{t(spec.labelKey as never)}</span>
              {!isDefault && (
                <button
                  onClick={() => setBindings(saveBinding(spec.id, null))}
                  className="shrink-0 font-mono text-[11px] text-fg-muted transition-colors hover:text-fg"
                  title={formatCombo(spec.default)}
                >
                  ↺
                </button>
              )}
              <button
                data-shortcut-row={spec.id}
                onClick={() => setRecording(recording === spec.id ? null : spec.id)}
                className={`kbd-combo shrink-0 rounded-md border px-2 py-1 text-[12px] transition-colors ${
                  recording === spec.id
                    ? "border-mint/60 text-mint"
                    : "border-line text-fg-muted hover:border-fg-muted hover:text-fg"
                }`}
              >
                {recording === spec.id ? t("shortcutPressKeys") : formatCombo(combo)}
              </button>
            </div>
          );
        })}
      </div>
      <button
        id="shortcuts-reset-all"
        onClick={() => setBindings(resetBindings())}
        className="rounded-md border border-line px-2.5 py-1 text-[13px] text-fg-muted transition-colors hover:text-fg"
      >
        {t("shortcutResetAll")}
      </button>

      {/* Reference-only guide for keys owned by the TUI apps themselves
          (claude code, zellij, …) — nothing here is rebindable, the data
          lives in keyGuide.ts. */}
      <div id="key-guide" className="space-y-3 border-t border-line pt-4">
        <div className="space-y-1">
          <span className="block text-[13px] font-medium text-fg">{t("keyGuideTitle")}</span>
          <p className="text-[12px] leading-relaxed text-fg-muted">{t("keyGuideDesc")}</p>
          {/* dala eats F2 before the shell sees it — say so where the TUI
              users look, and point them at the rebind above. */}
          <p id="key-guide-f2-note" className="text-[12px] leading-relaxed text-fg-muted">
            {t("keyGuideF2Note")}
          </p>
        </div>
        {KEY_GUIDE.map((group) => (
          <div key={group.app} className="space-y-1.5">
            <span className="block font-mono text-[11px] uppercase tracking-wide text-fg-muted/80">
              {group.app}
            </span>
            <div className="divide-y divide-line/60 rounded-lg border border-line">
              {group.rows.map((row) => (
                <div key={row.descKey} className="flex items-center gap-2 px-3 py-2">
                  <span className="flex-1 text-[12px] leading-relaxed text-fg">
                    {t(row.descKey)}
                  </span>
                  <span className="flex shrink-0 items-center gap-1">
                    {row.keys.map((key, index) => (
                      <span
                        key={index}
                        className="kbd-combo rounded-md border border-line px-2 py-1 text-[12px] text-fg-muted"
                      >
                        {key}
                      </span>
                    ))}
                  </span>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
