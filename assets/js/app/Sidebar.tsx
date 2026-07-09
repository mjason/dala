import React from "react";
import type { SessionUpdatedPayload } from "../ash_types";
import { authEnabled, userEmail } from "./meta";
import { shortPath } from "./util";
import { LOCALE_NAMES, useI18n } from "./i18n";
import type { Locale } from "./i18n";
import UpdateCheck from "./UpdateCheck";

export type Session = SessionUpdatedPayload;

type Props = {
  sessions: Session[];
  activeId: string | null;
  connected: boolean;
  creating: boolean;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onOpenSettings: (id: string) => void;
  onDelete: (id: string) => void;
};

export default function Sidebar({
  sessions,
  activeId,
  connected,
  creating,
  onSelect,
  onCreate,
  onOpenSettings,
  onDelete,
}: Props) {
  const { locale, t, setLocale } = useI18n();

  return (
    <aside className="flex h-full w-64 shrink-0 flex-col border-r border-line bg-bg1">
      <div className="flex items-center gap-2 px-4 pt-4 pb-3">
        <span className="font-mono text-[15px] font-semibold tracking-widest text-fg">DALA</span>
        <span
          className={`ml-1 inline-block h-1.5 w-1.5 rounded-full transition-colors ${
            connected ? "bg-mint" : "bg-danger animate-pulse"
          }`}
          title={connected ? t("connected") : t("reconnecting")}
        />
        <div className="flex-1" />
        <button
          id="new-session-button"
          onClick={onCreate}
          disabled={creating}
          className="grid h-7 w-7 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:border-fg-muted hover:text-fg disabled:opacity-50"
          title={t("newTerminal")}
        >
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M8 3v10M3 8h10" strokeLinecap="round" />
          </svg>
        </button>
      </div>

      <nav id="session-list" className="flex-1 overflow-y-auto px-2 pb-2">
        {sessions.length === 0 && (
          <div className="mt-10 px-3 text-center text-[13px] leading-6 text-fg-muted">
            {t("noTerminalsYet")}
            <br />
            <button onClick={onCreate} className="text-mint hover:underline">
              + {t("newTerminal")}
            </button>
          </div>
        )}
        {sessions.map((s) => {
          const active = s.id === activeId;
          return (
            <div
              key={s.id}
              onClick={() => onSelect(s.id)}
              className={`group mb-0.5 flex cursor-pointer items-center gap-2.5 rounded-lg px-2.5 py-2 transition-colors ${
                active ? "bg-bg2 text-fg" : "text-fg-muted hover:bg-bg2/60 hover:text-fg"
              }`}
            >
              <span
                className={`h-1.5 w-1.5 shrink-0 rounded-full ${
                  s.status === "running" ? "bg-mint" : "bg-fg-muted/50"
                }`}
              />
              <div className="min-w-0 flex-1">
                <div className="truncate font-mono text-sm">{s.name}</div>
                <div className="truncate font-mono text-xs text-fg-muted/80">
                  {shortPath(s.cwd, 28)}
                </div>
              </div>
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  onOpenSettings(s.id);
                }}
                className="hidden h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:text-fg group-hover:grid"
                title={t("sessionSettings")}
              >
                <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="currentColor">
                  <circle cx="3" cy="8" r="1.3" />
                  <circle cx="8" cy="8" r="1.3" />
                  <circle cx="13" cy="8" r="1.3" />
                </svg>
              </button>
              <button
                data-delete-session={s.id}
                onClick={(e) => {
                  e.stopPropagation();
                  onDelete(s.id);
                }}
                className="hidden h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:text-danger group-hover:grid"
                title={t("deleteSession")}
              >
                <svg
                  viewBox="0 0 16 16"
                  className="h-3.5 w-3.5"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.5"
                >
                  <path d="m4 4 8 8m0-8-8 8" strokeLinecap="round" />
                </svg>
              </button>
            </div>
          );
        })}
      </nav>

      <footer className="space-y-2 border-t border-line px-4 py-3 text-xs text-fg-muted">
        <div className="flex items-center justify-between gap-2">
          {authEnabled ? (
            <>
              <span className="truncate font-mono" title={userEmail ?? ""}>
                {userEmail}
              </span>
              <a href="/sign-out" className="shrink-0 transition-colors hover:text-fg">
                {t("signOut")}
              </a>
            </>
          ) : (
            <span className="font-mono">{t("localMode")}</span>
          )}
        </div>
        <UpdateCheck />
        <select
          id="language-select"
          aria-label={t("language")}
          value={locale}
          onChange={(e) => setLocale(e.target.value as Locale)}
          className="w-full rounded-md border border-line bg-bg0 px-1.5 py-1 text-xs text-fg-muted outline-none transition-colors hover:text-fg focus:border-mint/60"
        >
          {(Object.keys(LOCALE_NAMES) as Locale[]).map((code) => (
            <option key={code} value={code}>
              {LOCALE_NAMES[code]}
            </option>
          ))}
        </select>
      </footer>
    </aside>
  );
}
