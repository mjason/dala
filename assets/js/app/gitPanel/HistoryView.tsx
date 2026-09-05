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
  const rows = commits ? buildGraphRows(commits) : [];
  return (
    <div id="git-history" className="flex-1 overflow-y-auto py-1">
      {commits?.length === 0 && (
        <div className="px-3 py-8 text-center text-[13px] text-fg-muted">{t("noChanges")}</div>
      )}
      {rows.map(({ commit: c, lane, targets, width }) => (
        <button
          key={c.hash}
          onClick={() => onOpen(c)}
          className="flex w-full items-stretch gap-2 border-b border-line/40 px-3 py-2 text-left transition-colors hover:bg-bg2/70"
        >
          <CommitGraph lane={lane} targets={targets} width={width} />
          <span className="min-w-0 flex-1">
            <span className="block truncate font-mono text-[13px] text-fg">{c.subject}</span>
            <span className="flex items-center gap-2 font-mono text-[11px] text-fg-muted">
              <span className="text-git-modified">{c.hash}</span>
              <span className="truncate">{c.author}</span>
              <span className="shrink-0">{formatDate(c.date)}</span>
            </span>
          </span>
        </button>
      ))}
    </div>
  );
}

type GraphRow = {
  commit: Commit;
  lane: number;
  targets: number[];
  width: number;
};

/**
 * Turn the topological commit order into stable graph lanes. The first parent
 * stays in the current lane; merge parents fan out to adjacent lanes. Keeping
 * this pure makes the graph deterministic and cheap to test without a canvas.
 */
export function buildGraphRows(commits: Commit[]): GraphRow[] {
  let lanes: string[] = [];

  return commits.map((commit) => {
    const lane = Math.max(0, lanes.indexOf(commit.hash));
    if (lanes.length === 0) lanes = [commit.hash];
    else if (!lanes.includes(commit.hash)) lanes.splice(lane, 0, commit.hash);

    const parents = commit.parents ?? [];
    const next = lanes.slice();
    next.splice(lane, 1);
    for (const parent of parents) {
      const existing = next.indexOf(parent);
      if (existing >= 0) next.splice(existing, 1);
    }
    next.splice(lane, 0, ...parents);

    const targets = parents.map((parent) => Math.max(0, next.indexOf(parent)));
    const width = Math.max(1, lane + 1, ...targets.map((target) => target + 1));
    lanes = next;
    return { commit, lane, targets, width };
  });
}

function CommitGraph({ lane, targets, width }: Omit<GraphRow, "commit">) {
  const cell = 12;
  const height = 38;
  const x = lane * cell + cell / 2;
  return (
    <svg
      aria-hidden="true"
      data-graph-lane={lane}
      data-graph-parent-count={targets.length}
      width={Math.max(24, width * cell)}
      height={height}
      viewBox={`0 0 ${Math.max(24, width * cell)} ${height}`}
      className="shrink-0 overflow-visible text-fg-muted"
    >
      <line x1={x} y1={0} x2={x} y2={height} stroke="currentColor" strokeOpacity=".42" strokeWidth="1.5" />
      {targets.map((target, index) => {
        const tx = target * cell + cell / 2;
        return (
          <path
            key={`${target}-${index}`}
            d={`M ${x} 19 C ${x} 27, ${tx} 27, ${tx} ${height}`}
            fill="none"
            stroke="currentColor"
            strokeOpacity=".62"
            strokeWidth="1.5"
          />
        );
      })}
      <circle cx={x} cy={19} r={4} fill="var(--color-bg1)" stroke="currentColor" strokeWidth="2" />
    </svg>
  );
}
