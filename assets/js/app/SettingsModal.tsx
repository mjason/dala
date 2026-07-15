import React, { useEffect, useRef, useState } from "react";
import {
  closeSession,
  deleteSession,
  kickViewers,
  renameSession,
  restartSession,
  setScrollbackLimit,
} from "../ash_rpc";
import { call, type RpcOutcome } from "./rpc";
import { FieldLabel, TextInput } from "./ui";
import type { Session } from "./Sidebar";
import { useI18n } from "./i18n";
import { historyLines as normalizeHistoryLines } from "./util";
import { isTopWindow, Kbd, modCombo, popWindow, pushWindow } from "./shortcuts";
import AppearanceSection from "./settings/AppearanceSection";
import NotificationsSection from "./settings/NotificationsSection";
import ShortcutsSection from "./settings/ShortcutsSection";
import SpeechSection from "./settings/SpeechSection";

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
  const [tab, setTab] = useState<"session" | "appearance" | "shortcuts" | "voice">("session");
  const [name, setName] = useState(session.name);
  const [historyLines, setHistoryLines] = useState(() =>
    normalizeHistoryLines(session.scrollbackLimit),
  );
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  // Each tab starts at the top: the scroll position of the (long) Shortcuts
  // tab must not carry over into the next one.
  const bodyRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => bodyRef.current?.scrollTo(0, 0), [tab]);

  const fail = (error: string) => onError(error || t("somethingWentWrong"));

  const save = async () => {
    setBusy(true);

    if (name.trim() && name.trim() !== session.name) {
      const result = await call<unknown>(renameSession, {
        identity: session.id,
        input: { name: name.trim() },
      });
      if (!result.ok) fail(result.error);
    }

    const limit = Math.min(Math.max(historyLines, LINES_MIN), LINES_MAX);
    if (limit !== session.scrollbackLimit) {
      const result = await call<unknown>(setScrollbackLimit, {
        identity: session.id,
        input: { scrollbackLimit: limit },
      });
      if (!result.ok) fail(result.error);
    }

    setBusy(false);
    onClose();
  };

  // Esc closes, Ctrl/Cmd+S saves. The modal joins the window stack so Esc
  // only ever closes the topmost layer.
  const handlersRef = useRef({ save, onClose, busy });
  handlersRef.current = { save, onClose, busy };
  useEffect(() => {
    const token = pushWindow();
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !e.defaultPrevented && isTopWindow(token)) {
        e.preventDefault();
        handlersRef.current.onClose();
      }
      if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "s") {
        e.preventDefault();
        if (!handlersRef.current.busy) void handlersRef.current.save();
      }
    };
    window.addEventListener("keydown", handler);
    return () => {
      window.removeEventListener("keydown", handler);
      popWindow(token);
    };
  }, []);

  const act = async (fn: () => Promise<RpcOutcome<unknown>>) => {
    setBusy(true);
    const result = await fn();
    setBusy(false);
    if (!result.ok) fail(result.error);
  };

  const running = session.status === "running";

  const tabs: { key: "session" | "appearance" | "shortcuts" | "voice"; label: string }[] = [
    { key: "session", label: t("sessionTab") },
    { key: "appearance", label: t("preferencesTab") },
    { key: "shortcuts", label: t("shortcutsTab") },
    { key: "voice", label: t("speechSection") },
  ];

  // ARIA roving-tabindex keyboard nav: Left/Right (and Home/End) move focus
  // AND selection between tabs, per the tabs pattern. Only the active tab is
  // in the tab order; the arrows walk the rest.
  const onTabKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    // Anchor on the FOCUSED tab (roving tabindex), not the selected one — they
    // track together in normal use, but keying off focus is what the WAI-ARIA
    // tabs pattern specifies.
    const focusedKey = (e.target as HTMLElement)?.getAttribute?.("data-settings-tab");
    const anchor = tabs.findIndex((x) => x.key === focusedKey);
    const idx = anchor === -1 ? tabs.findIndex((x) => x.key === tab) : anchor;
    let nextIdx: number | null = null;
    if (e.key === "ArrowRight" || e.key === "ArrowDown") nextIdx = (idx + 1) % tabs.length;
    else if (e.key === "ArrowLeft" || e.key === "ArrowUp")
      nextIdx = (idx - 1 + tabs.length) % tabs.length;
    else if (e.key === "Home") nextIdx = 0;
    else if (e.key === "End") nextIdx = tabs.length - 1;
    if (nextIdx === null) return;
    e.preventDefault();
    const nextKey = tabs[nextIdx].key;
    setTab(nextKey);
    document.getElementById(`settings-tab-${nextKey}`)?.focus();
  };

  return (
    <div
      className="fixed inset-0 z-40 grid place-items-center overflow-hidden bg-black/60 p-4 backdrop-blur-[2px] sm:p-6"
      onClick={onClose}
    >
      {/* The cap follows the VISUAL viewport (--vvh, published by index.tsx)
          so a raised soft keyboard shrinks the modal instead of pushing the
          footer under the keyboard; the inset mirrors the overlay's p-4/sm:p-6.
          `min-w-0`: as a grid item the box's default `min-width: auto` lets
          wide content push it past the centered grid area and out of the
          viewport (overflow-hidden then clips its right edge) — cap it at the
          area's width and let inner content wrap/scroll instead. */}
      <div
        id="session-settings"
        className="flex max-h-[calc(var(--vvh,100dvh)-2rem)] w-full min-w-0 max-w-lg flex-col animate-[dala-modal-in_150ms_ease-out] rounded-xl border border-line bg-bg1 shadow-2xl shadow-black/50 sm:max-h-[calc(var(--vvh,100dvh)-3rem)]"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex shrink-0 items-center gap-3 px-5 pt-4 pb-3">
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

        {/* Four tabs on one row only survive on `sm` and up. At 390px the row
            leaves ~52px of text per cell — measured at 13px, EVERY locale's
            longest label blows past that (zh-CN 语音输入 52px, de
            Spracheingabe 97.5px, ru Горячие клавиши 120.8px), so the strip
            overflowed and clipped the last tab. Narrow screens get a 2×2
            grid instead: ~131px of text per cell at 390px, ~104px at 320px —
            every label fits, and the ones that don't (ru at 320) wrap inside
            their button instead of being cut off. `break-words` keeps a long
            unbreakable word (de) from pushing the track wider than the modal.
            Desktop (`sm:`) is untouched: 4 columns, px-3. */}
        <div className="shrink-0 px-5">
          <div
            role="tablist"
            aria-label={t("sessionSettings")}
            onKeyDown={onTabKeyDown}
            className="grid grid-cols-2 gap-0.5 rounded-lg border border-line bg-bg0 p-0.5 sm:grid-cols-4"
          >
            {tabs.map(({ key, label }) => (
              <button
                key={key}
                id={`settings-tab-${key}`}
                role="tab"
                aria-selected={tab === key}
                aria-controls="settings-body"
                tabIndex={tab === key ? 0 : -1}
                data-settings-tab={key}
                onClick={() => setTab(key)}
                className={`min-w-0 break-words rounded-md px-2 py-1.5 text-[13px] transition-colors sm:px-3 ${
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

        {/* The comfort min-height only applies when there is room for it in
            BOTH axes: `sm:` alone is width-only, and a landscape phone
            (844×390) would pin the body to 21rem, overflow the capped modal
            and clip the save button. */}
        <div
          id="settings-body"
          ref={bodyRef}
          role="tabpanel"
          aria-labelledby={`settings-tab-${tab}`}
          className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4 [@media(min-width:640px)_and_(min-height:44rem)]:min-h-[21rem]"
        >
          {tab === "session" ? (
            <>
              <label className="block space-y-1.5">
                <FieldLabel>{t("name")}</FieldLabel>
                {/* Headline input: the one sanctioned deviation from the
                    13px spec — the session name reads as a title. */}
                <TextInput
                  id="session-name-input"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="text-[15px]"
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
                  {/* Fixed width via wrapper: .w-full is emitted after .w-20
                      in the stylesheet, so it cannot be overridden inline. */}
                  <div className="w-20 shrink-0">
                    <TextInput
                      type="number"
                      min={LINES_MIN}
                      max={LINES_MAX}
                      step={1000}
                      value={historyLines}
                      onChange={(e) => setHistoryLines(Number(e.target.value) || 10_000)}
                      className="text-right"
                    />
                  </div>
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
                        void act(() => call<unknown>(closeSession, { input: { id: session.id } }))
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
                          call<unknown>(restartSession, { input: { id: session.id } }),
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
                          const result = await call<{
                            multiplexer: string;
                            kicked: number;
                            error: string | null;
                          }>(kickViewers, {
                            input: { id: session.id },
                            fields: ["multiplexer", "session", "kicked", "error"],
                          });
                          if (result.ok) {
                            const data = result.data;
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
                          const result = await call<unknown>(deleteSession, {
                            identity: session.id,
                          });
                          if (result.ok) {
                            onDeleted();
                            onClose();
                          }
                          return result;
                        })
                      }
                      disabled={busy}
                      className="rounded-md bg-danger/90 px-2.5 py-1 text-[13px] font-medium text-bg0 transition-colors hover:bg-danger disabled:opacity-50"
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
          ) : tab === "shortcuts" ? (
            <ShortcutsSection />
          ) : tab === "voice" ? (
            <SpeechSection root={session.cwd} />
          ) : (
            <>
              <AppearanceSection onError={fail} />
              <NotificationsSection />
            </>
          )}
        </div>

        <footer className="flex shrink-0 items-center justify-end gap-2 border-t border-line px-5 py-3">
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
            className="inline-flex items-center gap-1.5 rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-bg0 transition-all hover:brightness-110 active:scale-[0.98] disabled:opacity-50"
          >
            {t("save")} <Kbd>{modCombo("s")}</Kbd>
          </button>
        </footer>
      </div>
    </div>
  );
}
