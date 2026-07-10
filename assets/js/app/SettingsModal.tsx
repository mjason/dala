import React, { useEffect, useRef, useState } from "react";
import {
  buildCSRFHeaders,
  closeSession,
  deleteSession,
  renameSession,
  restartSession,
  setScrollbackLimit,
} from "../ash_rpc";
import type { Session } from "./Sidebar";
import { useI18n } from "./i18n";
import { historyLines as normalizeHistoryLines } from "./util";
import { Kbd, modCombo } from "./shortcuts";
import {
  DEFAULT_PREFS,
  FONT_SIZE_RANGE,
  LINE_HEIGHT_RANGE,
  loadPrefs,
  resetPrefs,
  savePrefs,
} from "./termPrefs";
import type { CursorStyle, TermPrefs } from "./termPrefs";

const LINES_MIN = 1_000;
const LINES_MAX = 50_000;

type Props = {
  session: Session;
  onClose: () => void;
  onDeleted: () => void;
  onError: (message: string) => void;
};

export default function SettingsModal({ session, onClose, onDeleted, onError }: Props) {
  const { t } = useI18n();
  const [name, setName] = useState(session.name);
  const [historyLines, setHistoryLines] = useState(() => normalizeHistoryLines(session.scrollbackLimit));
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const fail = (errors: { message: string }[]) =>
    onError(errors[0]?.message ?? t("somethingWentWrong"));

  const save = async () => {
    setBusy(true);
    const headers = buildCSRFHeaders();

    if (name.trim() && name.trim() !== session.name) {
      const result = await renameSession({
        identity: session.id,
        input: { name: name.trim() },
        headers,
      });
      if (!result.success) fail(result.errors);
    }

    const limit = Math.min(Math.max(historyLines, LINES_MIN), LINES_MAX);
    if (limit !== session.scrollbackLimit) {
      const result = await setScrollbackLimit({
        identity: session.id,
        input: { scrollbackLimit: limit },
        headers,
      });
      if (!result.success) fail(result.errors);
    }

    setBusy(false);
    onClose();
  };

  // Esc closes, Ctrl/Cmd+S saves.
  const handlersRef = useRef({ save, onClose, busy });
  handlersRef.current = { save, onClose, busy };
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !e.defaultPrevented) {
        e.preventDefault();
        handlersRef.current.onClose();
      }
      if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "s") {
        e.preventDefault();
        if (!handlersRef.current.busy) void handlersRef.current.save();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  const act = async (fn: () => Promise<{ success: boolean; errors?: any }>) => {
    setBusy(true);
    const result = await fn();
    setBusy(false);
    if (!result.success) fail(result.errors);
  };

  return (
    <div
      className="fixed inset-0 z-40 grid place-items-center overflow-y-auto bg-black/60 p-4 sm:p-6"
      onClick={onClose}
    >
      <div
        id="session-settings"
        className="w-full max-w-sm rounded-xl border border-line bg-bg1 shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-center justify-between border-b border-line px-4 py-3">
          <span className="text-[15px] font-medium text-fg">{t("sessionSettings")}</span>
          <span
            className={`font-mono text-xs ${
              session.status === "running" ? "text-mint" : "text-fg-muted"
            }`}
          >
            {session.status === "running"
              ? t("running")
              : session.exitCode != null
                ? t("exitedWithCode", { code: session.exitCode })
                : t("exited")}
          </span>
        </header>

        <div className="space-y-4 px-4 py-4">
          <label className="block">
            <span className="mb-1 block text-xs uppercase tracking-wider text-fg-muted">
              {t("name")}
            </span>
            <input
              id="session-name-input"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="w-full rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[15px] text-fg outline-none transition-colors focus:border-mint/60"
            />
          </label>

          <label className="block">
            <span className="mb-1 block text-xs uppercase tracking-wider text-fg-muted">
              {t("scrollbackCache")} · {historyLines.toLocaleString()}
            </span>
            <div className="flex items-center gap-3">
              <input
                id="scrollback-limit-input"
                type="range"
                min={LINES_MIN}
                max={LINES_MAX}
                step={1000}
                value={historyLines}
                onChange={(e) => setHistoryLines(Number(e.target.value))}
                className="flex-1 accent-[#4cc38a]"
              />
              <input
                type="number"
                min={LINES_MIN}
                max={LINES_MAX}
                step={1000}
                value={historyLines}
                onChange={(e) => setHistoryLines(Number(e.target.value) || 10_000)}
                className="w-20 rounded-md border border-line bg-bg0 px-2 py-1 text-right font-mono text-[13px] text-fg outline-none focus:border-mint/60"
              />
            </div>
            <span className="mt-1 block text-xs leading-5 text-fg-muted/80">
              {t("scrollbackHint")}
            </span>
          </label>

          <AppearanceSection />

          <div className="flex gap-2 border-t border-line pt-3">
            {session.status === "running" ? (
              <button
                onClick={() =>
                  void act(() =>
                    closeSession({ input: { id: session.id }, headers: buildCSRFHeaders() }),
                  )
                }
                disabled={busy}
                className="rounded-md border border-line px-2.5 py-1 text-[13px] text-fg-muted transition-colors hover:border-danger/60 hover:text-danger disabled:opacity-50"
              >
                {t("killShell")}
              </button>
            ) : (
              <button
                id="restart-session-button"
                onClick={() =>
                  void act(() =>
                    restartSession({ input: { id: session.id }, headers: buildCSRFHeaders() }),
                  )
                }
                disabled={busy}
                className="rounded-md border border-mint/50 px-2.5 py-1 text-[13px] text-mint transition-colors hover:bg-mint/10 disabled:opacity-50"
              >
                {t("restartShell")}
              </button>
            )}
            <div className="flex-1" />
            {confirmDelete ? (
              <button
                onClick={() =>
                  void act(async () => {
                    const result = await deleteSession({
                      identity: session.id,
                      headers: buildCSRFHeaders(),
                    });
                    if (result.success) {
                      onDeleted();
                      onClose();
                    }
                    return result;
                  })
                }
                disabled={busy}
                className="rounded-md bg-danger/90 px-2.5 py-1 text-[13px] font-medium text-black transition-colors hover:bg-danger disabled:opacity-50"
              >
                {t("reallyDelete")}
              </button>
            ) : (
              <button
                id="delete-session-button"
                onClick={() => setConfirmDelete(true)}
                className="rounded-md border border-line px-2.5 py-1 text-[13px] text-fg-muted transition-colors hover:border-danger/60 hover:text-danger"
              >
                {t("deleteSession")}
              </button>
            )}
          </div>
        </div>

        <footer className="flex justify-end gap-2 border-t border-line px-4 py-3">
          <button
            onClick={onClose}
            className="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-[13px] text-fg-muted transition-colors hover:text-fg"
          >
            {t("cancel")} <Kbd>Esc</Kbd>
          </button>
          <button
            id="save-settings-button"
            onClick={() => void save()}
            disabled={busy}
            className="inline-flex items-center gap-1.5 rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-black transition-colors hover:brightness-110 disabled:opacity-50"
          >
            {t("save")} <Kbd>{modCombo("s")}</Kbd>
          </button>
        </footer>
      </div>
    </div>
  );
}

/**
 * Terminal appearance (font, size, line height, cursor). Browser-local and
 * global across sessions; every change persists and applies to open
 * terminals immediately, so there is no save step.
 */
function AppearanceSection() {
  const { t } = useI18n();
  const [prefs, setPrefs] = useState<TermPrefs>(loadPrefs);

  const apply = (patch: Partial<TermPrefs>) => setPrefs(savePrefs(patch));

  const cursorStyles: { value: CursorStyle; label: string }[] = [
    { value: "bar", label: t("cursorBar") },
    { value: "block", label: t("cursorBlock") },
    { value: "underline", label: t("cursorUnderline") },
  ];

  return (
    <div className="space-y-3 border-t border-line pt-3">
      <div className="flex items-baseline justify-between">
        <span className="text-xs uppercase tracking-wider text-fg-muted">{t("appearance")}</span>
        <button
          id="appearance-reset-button"
          onClick={() => setPrefs(resetPrefs())}
          className="text-xs text-fg-muted transition-colors hover:text-fg"
        >
          {t("resetDefaults")}
        </button>
      </div>
      <span className="block text-xs leading-5 text-fg-muted/80">{t("appearanceScope")}</span>

      <label className="block">
        <span className="mb-1 block text-xs text-fg-muted">
          {t("fontSize")} · {prefs.fontSize}px
        </span>
        <div className="flex items-center gap-3">
          <input
            id="font-size-input"
            type="range"
            min={FONT_SIZE_RANGE.min}
            max={FONT_SIZE_RANGE.max}
            value={prefs.fontSize}
            onChange={(e) => apply({ fontSize: Number(e.target.value) })}
            className="flex-1 accent-[#4cc38a]"
          />
          <input
            type="number"
            min={FONT_SIZE_RANGE.min}
            max={FONT_SIZE_RANGE.max}
            value={prefs.fontSize}
            onChange={(e) => apply({ fontSize: Number(e.target.value) || DEFAULT_PREFS.fontSize })}
            className="w-16 rounded-md border border-line bg-bg0 px-2 py-1 text-right font-mono text-[13px] text-fg outline-none focus:border-mint/60"
          />
        </div>
      </label>

      <label className="block">
        <span className="mb-1 block text-xs text-fg-muted">
          {t("lineHeight")} · {prefs.lineHeight.toFixed(2)}
        </span>
        <input
          id="line-height-input"
          type="range"
          min={LINE_HEIGHT_RANGE.min}
          max={LINE_HEIGHT_RANGE.max}
          step={0.05}
          value={prefs.lineHeight}
          onChange={(e) => apply({ lineHeight: Number(e.target.value) })}
          className="w-full accent-[#4cc38a]"
        />
      </label>

      <label className="block">
        <span className="mb-1 block text-xs text-fg-muted">{t("fontFamily")}</span>
        <input
          id="font-family-input"
          value={prefs.fontFamily}
          onChange={(e) => apply({ fontFamily: e.target.value })}
          placeholder='JetBrainsMono NFM'
          spellCheck={false}
          className="w-full rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[13px] text-fg outline-none transition-colors placeholder:text-fg-muted/50 focus:border-mint/60"
        />
        <span className="mt-1 block text-xs leading-5 text-fg-muted/80">{t("fontFamilyHint")}</span>
      </label>

      <div className="flex items-center gap-4">
        <div className="flex items-center gap-0.5 rounded-md border border-line p-0.5">
          {cursorStyles.map(({ value, label }) => (
            <button
              key={value}
              data-cursor-style={value}
              onClick={() => apply({ cursorStyle: value })}
              className={`rounded px-2 py-0.5 text-xs transition-colors ${
                prefs.cursorStyle === value ? "bg-bg2 text-mint" : "text-fg-muted hover:text-fg"
              }`}
            >
              {label}
            </button>
          ))}
        </div>
        <label className="flex cursor-pointer items-center gap-1.5 text-xs text-fg-muted">
          <input
            id="cursor-blink-checkbox"
            type="checkbox"
            checked={prefs.cursorBlink}
            onChange={(e) => apply({ cursorBlink: e.target.checked })}
            className="h-3.5 w-3.5 accent-[#4cc38a]"
          />
          {t("cursorBlink")}
        </label>
        <label className="flex cursor-pointer items-center gap-1.5 text-xs text-fg-muted">
          <input
            id="smooth-scroll-checkbox"
            type="checkbox"
            checked={prefs.smoothScroll}
            onChange={(e) => apply({ smoothScroll: e.target.checked })}
            className="h-3.5 w-3.5 accent-[#4cc38a]"
          />
          {t("smoothScroll")}
        </label>
      </div>
    </div>
  );
}
