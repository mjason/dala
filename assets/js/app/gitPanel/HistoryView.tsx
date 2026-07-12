import React from "react";
import { useI18n } from "../i18n";
import type { Commit } from "./types";

export function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** The history tab: the commit log, each entry opening its patch. */
export default function HistoryView({
  commits,
  onOpen,
}: {
  commits: Commit[] | null;
  onOpen: (commit: Commit) => void;
}) {
  const { t } = useI18n();
  return (
    <div id="git-history" className="flex-1 overflow-y-auto py-1">
      {commits?.length === 0 && (
        <div className="px-3 py-8 text-center text-[13px] text-fg-muted">{t("noChanges")}</div>
      )}
      {commits?.map((c) => (
        <button
          key={c.hash}
          onClick={() => onOpen(c)}
          className="flex w-full flex-col gap-0.5 border-b border-line/40 px-3 py-2 text-left transition-colors hover:bg-bg2/70"
        >
          <span className="truncate font-mono text-[13px] text-fg">{c.subject}</span>
          <span className="flex items-center gap-2 font-mono text-[11px] text-fg-muted">
            <span className="text-[#d9a860]">{c.hash}</span>
            <span className="truncate">{c.author}</span>
            <span className="shrink-0">{formatDate(c.date)}</span>
          </span>
        </button>
      ))}
    </div>
  );
}
