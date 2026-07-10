import React, { useEffect, useRef, useState } from "react";
import {
  buildCSRFHeaders,
  closeSession,
  deleteSession,
  kickViewers,
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
  SCROLL_SENSITIVITY_RANGE,
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

/** Small right-aligned monospace value chip next to a control label. */
function ValueChip({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded border border-line bg-bg0 px-1.5 py-0.5 font-mono text-[11px] tabular-nums text-fg">
      {children}
    </span>
  );
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return <span className="text-xs text-fg-muted">{children}</span>;
}

/** iOS-style switch; keeps a hidden checkbox for the stable input id. */
function Toggle({
  id,
  checked,
  onChange,
}: {
  id: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className={`relative h-5 w-9 shrink-0 rounded-full transition-colors duration-150 ${
        checked ? "bg-mint" : "bg-bg2 ring-1 ring-inset ring-line"
      }`}
    >
      <input id={id} type="checkbox" checked={checked} readOnly className="sr-only" />
      <span
        className={`absolute top-0.5 left-0.5 h-4 w-4 rounded-full transition-transform duration-150 ${
          checked ? "translate-x-4 bg-black/80" : "bg-fg-muted"
        }`}
      />
    </button>
  );
}

function ToggleRow({
  id,
  label,
  checked,
  onChange,
}: {
  id: string;
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label
      className="flex cursor-pointer items-center justify-between gap-3 px-3 py-2 transition-colors hover:bg-bg2/40"
      onClick={(e) => {
        e.preventDefault();
        onChange(!checked);
      }}
    >
      <span className="text-[13px] text-fg">{label}</span>
      <Toggle id={id} checked={checked} onChange={onChange} />
    </label>
  );
}

export default function SettingsModal({ session, onClose, onDeleted, onError }: Props) {
  const { t } = useI18n();
  const [tab, setTab] = useState<"session" | "appearance">("session");
  const [name, setName] = useState(session.name);
  const [historyLines, setHistoryLines] = useState(() =>
    normalizeHistoryLines(session.scrollbackLimit),
  );
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

  const running = session.status === "running";

  const tabs: { key: "session" | "appearance"; label: string }[] = [
    { key: "session", label: t("sessionTab") },
    { key: "appearance", label: t("appearance") },
  ];

  return (
    <div
      className="fixed inset-0 z-40 grid place-items-center overflow-y-auto bg-black/60 p-4 backdrop-blur-[2px] sm:p-6"
      onClick={onClose}
    >
      <div
        id="session-settings"
        className="w-full max-w-lg animate-[dala-modal-in_150ms_ease-out] rounded-xl border border-line bg-bg1 shadow-2xl shadow-black/50"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-center gap-3 px-5 pt-4 pb-3">
          <span className="text-[15px] font-medium text-fg">{t("sessionSettings")}</span>
          <span
            className={`inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 font-mono text-[11px] ${
              running ? "bg-mint/10 text-mint" : "bg-bg2 text-fg-muted"
            }`}
          >
            <span
              className={`h-1.5 w-1.5 rounded-full ${running ? "bg-mint" : "bg-fg-muted/60"}`}
            />
            {running
              ? t("running")
              : session.exitCode != null
                ? t("exitedWithCode", { code: session.exitCode })
                : t("exited")}
          </span>
          <div className="flex-1" />
          <button
            id="settings-close-button"
            onClick={onClose}
            className="grid h-7 w-7 place-items-center rounded-md text-fg-muted transition-colors hover:bg-bg2 hover:text-fg"
            title={t("close")}
          >
            <svg
              viewBox="0 0 16 16"
              className="h-3.5 w-3.5"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
            >
              <path d="m3 3 10 10M13 3 3 13" strokeLinecap="round" />
            </svg>
          </button>
        </header>

        <div className="px-5">
          <div className="grid grid-cols-2 gap-0.5 rounded-lg border border-line bg-bg0 p-0.5">
            {tabs.map(({ key, label }) => (
              <button
                key={key}
                data-settings-tab={key}
                onClick={() => setTab(key)}
                className={`rounded-md px-3 py-1.5 text-[13px] transition-colors ${
                  tab === key
                    ? "bg-bg2 font-medium text-fg shadow-sm"
                    : "text-fg-muted hover:text-fg"
                }`}
              >
                {label}
              </button>
            ))}
          </div>
        </div>

        <div className="min-h-[21rem] space-y-4 px-5 py-4">
          {tab === "session" ? (
            <>
              <label className="block space-y-1.5">
                <FieldLabel>{t("name")}</FieldLabel>
                <input
                  id="session-name-input"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="w-full rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[15px] text-fg outline-none transition-colors focus:border-mint/60 focus:ring-2 focus:ring-mint/20"
                />
              </label>

              <div className="space-y-1.5">
                <FieldLabel>{t("scrollbackCache")}</FieldLabel>
                <div className="flex items-center gap-3">
                  <input
                    id="scrollback-limit-input"
                    type="range"
                    min={LINES_MIN}
                    max={LINES_MAX}
                    step={1000}
                    value={historyLines}
                    onChange={(e) => setHistoryLines(Number(e.target.value))}
                    className="flex-1"
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
                <span className="block text-xs leading-5 text-fg-muted/80">
                  {t("scrollbackHint")}
                </span>
              </div>

              <div className="space-y-2 rounded-lg border border-line/70 p-3">
                <div className="flex items-center justify-between gap-3">
                  <span className="text-[13px] text-fg">
                    {running ? t("killShell") : t("restartShell")}
                  </span>
                  {running ? (
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
                          restartSession({
                            input: { id: session.id },
                            headers: buildCSRFHeaders(),
                          }),
                        )
                      }
                      disabled={busy}
                      className="rounded-md border border-mint/50 px-2.5 py-1 text-[13px] text-mint transition-colors hover:bg-mint/10 disabled:opacity-50"
                    >
                      {t("restartShell")}
                    </button>
                  )}
                </div>
                {running && (
                  <div className="flex items-center justify-between gap-3 border-t border-line/70 pt-2">
                    <div className="min-w-0">
                      <span className="block text-[13px] text-fg">{t("kickViewers")}</span>
                      <span className="block text-xs text-fg-muted/80">
                        {t("kickViewersHint")}
                      </span>
                    </div>
                    <button
                      id="kick-viewers-button"
                      onClick={() =>
                        void act(async () => {
                          const result = await kickViewers({
                            input: { id: session.id },
                            fields: ["multiplexer", "session", "kicked", "error"],
                            headers: buildCSRFHeaders(),
                          });
                          if (result.success) {
                            const data = result.data as unknown as {
                              multiplexer: string;
                              kicked: number;
                              error: string | null;
                            };
                            onError(
                              data.error ??
                                t("kickedViewers", {
                                  count: data.kicked,
                                  mux: data.multiplexer,
                                }),
                            );
                          }
                          return result;
                        })
                      }
                      disabled={busy}
                      className="shrink-0 rounded-md border border-line px-2.5 py-1 text-[13px] text-fg-muted transition-colors hover:border-mint/60 hover:text-mint disabled:opacity-50"
                    >
                      {t("kickViewersAction")}
                    </button>
                  </div>
                )}
                <div className="flex items-center justify-between gap-3 border-t border-line/70 pt-2">
                  <span className="text-[13px] text-fg">{t("deleteSession")}</span>
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
            </>
          ) : (
            <AppearanceSection />
          )}
        </div>

        <footer className="flex items-center justify-end gap-2 border-t border-line px-5 py-3">
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
            className="inline-flex items-center gap-1.5 rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-black transition-all hover:brightness-110 active:scale-[0.98] disabled:opacity-50"
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
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-3">
        <span className="text-xs leading-5 text-fg-muted/80">
          {t("appearanceScope")}
          {typeof document !== "undefined" && document.documentElement.dataset.termRenderer && (
            <span className="ml-2 font-mono text-[10px] uppercase text-fg-muted/60">
              {t("renderer")}: {document.documentElement.dataset.termRenderer}
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
          <input
            type="number"
            min={FONT_SIZE_RANGE.min}
            max={FONT_SIZE_RANGE.max}
            value={prefs.fontSize}
            onChange={(e) => apply({ fontSize: Number(e.target.value) || DEFAULT_PREFS.fontSize })}
            className="w-16 rounded-md border border-line bg-bg0 px-2 py-1 text-right font-mono text-[13px] text-fg outline-none focus:border-mint/60"
          />
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
        <input
          id="font-family-input"
          value={prefs.fontFamily}
          onChange={(e) => apply({ fontFamily: e.target.value })}
          placeholder="JetBrainsMono NFM"
          spellCheck={false}
          className="w-full rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[13px] text-fg outline-none transition-colors placeholder:text-fg-muted/50 focus:border-mint/60 focus:ring-2 focus:ring-mint/20"
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
      </div>
    </div>
  );
}
