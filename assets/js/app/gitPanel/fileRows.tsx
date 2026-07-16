import React from "react";
import { FileTypeIcon } from "../fileIcons";
import type { GitFile } from "./types";

export function GroupLabel({
  children,
  action,
}: {
  children: React.ReactNode;
  action?: { id: string; label: string; onClick: () => void };
}) {
  return (
    <div className="flex items-center px-3 pb-0.5 pt-1.5 font-mono text-[10px] uppercase tracking-wider text-fg-muted/70">
      {children}
      <div className="flex-1" />
      {action && (
        <button
          id={action.id}
          onClick={action.onClick}
          className="rounded border border-line px-1.5 py-px normal-case tracking-normal text-fg-muted transition-colors hover:border-mint/50 hover:text-mint"
        >
          {action.label}
        </button>
      )}
    </div>
  );
}

export type RowAction = {
  key: string;
  label: string;
  title: string;
  danger?: boolean;
  onClick: () => void;
};

export function FileRow({
  file,
  busy,
  onOpen,
  actions,
}: {
  file: GitFile;
  busy: string | null;
  onOpen: () => void;
  actions: RowAction[];
}) {
  return (
    <div className="group flex items-center gap-2 px-3 py-[5px] transition-colors hover:bg-bg2/70">
      <StatusBadge status={file.status} />
      <button onClick={onOpen} className="flex min-w-0 flex-1 items-center gap-1.5 text-left">
        <FileTypeIcon name={file.path} />
        <span className="min-w-0 flex-1 truncate font-mono text-[13px] text-fg">{file.path}</span>
      </button>
      {busy === `diff:${file.path}` && <span className="font-mono text-[11px] text-mint">…</span>}
      <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100">
        {actions.map((action) => (
          <button
            key={action.key}
            onClick={action.onClick}
            disabled={busy === `${action.key}:${file.path}`}
            title={action.title}
            className={`grid h-5 w-5 place-items-center rounded font-mono text-sm leading-none transition-colors disabled:opacity-40 ${
              action.danger
                ? "text-fg-muted hover:bg-danger/20 hover:text-danger"
                : "text-fg-muted hover:bg-mint/20 hover:text-mint"
            }`}
          >
            {action.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  const padded = status.padEnd(2, " ").slice(0, 2);
  const conflict = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].includes(padded);
  const code = conflict ? "!" : status === "??" ? "U" : status.trim().slice(0, 1) || "·";
  const color = conflict
    ? "text-git-conflict"
    : code === "A"
      ? "text-git-added"
      : code === "M"
        ? "text-git-modified"
        : code === "D"
          ? "text-git-deleted"
          : code === "R" || code === "C"
            ? "text-git-renamed"
            : code === "U"
              ? "text-git-untracked"
              : "text-fg-muted";

  return (
    <span className={`w-4 shrink-0 text-center font-mono text-xs font-semibold ${color}`}>{code}</span>
  );
}
