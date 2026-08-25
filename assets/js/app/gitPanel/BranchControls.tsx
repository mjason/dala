import React, { useState } from "react";
import { gitBranches } from "../../ash_rpc";
import type { GitBranchesFields } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
import type { BranchInfo, Branches } from "./types";

const BRANCH_FIELDS = ["current", "local", "remote"] as unknown as GitBranchesFields;

/**
 * The header's branch button + dropdown: lists local/remote branches on
 * open and hands the picked branch to the parent for checkout.
 */
export default function BranchControls({
  path,
  branch,
  onError,
  onSwitch,
}: {
  /** Repo path to list branches for (the resolved root, or the raw path). */
  path: string;
  /** Current branch name shown on the button. */
  branch: string;
  onError: (message: string) => void;
  onSwitch: (branch: BranchInfo) => void;
}) {
  const { t } = useI18n();
  const [branchMenu, setBranchMenu] = useState(false);
  const [branches, setBranches] = useState<Branches | null>(null);

  const openBranchMenu = async () => {
    setBranchMenu(true);
    setBranches(null);
    const result = await call<Branches>(gitBranches, {
      input: { path },
      fields: BRANCH_FIELDS,
    });
    if (result.ok) {
      setBranches(result.data);
    } else {
      setBranchMenu(false);
      onError(result.error || t("somethingWentWrong"));
    }
  };

  const pick = (item: BranchInfo) => {
    setBranchMenu(false);
    onSwitch(item);
  };

  return (
    <div className="relative min-w-0">
      <button
        id="branch-menu-button"
        onClick={() => (branchMenu ? setBranchMenu(false) : void openBranchMenu())}
        title={t("branches")}
        className="flex min-w-0 items-center gap-1 rounded px-1 py-0.5 font-mono text-xs text-mint transition-colors hover:bg-bg2"
      >
        <BranchIcon />
        <span className="truncate">{branch}</span>
        <svg viewBox="0 0 16 16" className="h-2.5 w-2.5 shrink-0 opacity-60" fill="none" stroke="currentColor" strokeWidth="1.5">
          <path d="M4 6l4 4 4-4" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
      {branchMenu && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setBranchMenu(false)} />
          <div
            id="branch-menu"
            className="absolute left-0 top-full z-50 mt-1 max-h-80 w-64 overflow-y-auto rounded-md border border-line bg-bg1 py-1 shadow-xl shadow-black/40"
          >
            {branches === null ? (
              <div className="px-3 py-2 text-xs text-fg-muted">…</div>
            ) : (
              <>
                <div className="px-2.5 pb-0.5 pt-1 text-[10px] uppercase tracking-wider text-fg-muted">
                  {t("localBranches")}
                </div>
                {branches.local.map((item) => (
                  <BranchRow
                    key={item.name}
                    branch={item}
                    current={Boolean(item.current) || item.name === branches.current}
                    onClick={() => pick(item)}
                  />
                ))}
                {branches.remote.length > 0 && (
                  <>
                    <div className="mt-1 border-t border-line/60 px-2.5 pb-0.5 pt-1.5 text-[10px] uppercase tracking-wider text-fg-muted">
                      {t("remoteBranches")}
                    </div>
                    {branches.remote.map((item) => (
                      <BranchRow
                        key={item.name}
                        branch={item}
                        current={false}
                        onClick={() => pick(item)}
                      />
                    ))}
                  </>
                )}
              </>
            )}
          </div>
        </>
      )}
    </div>
  );
}

function BranchRow({
  branch,
  current,
  onClick,
}: {
  branch: BranchInfo;
  current: boolean;
  onClick: () => void;
}) {
  return (
    <button
      data-branch={branch.name}
      onClick={onClick}
      className={`flex w-full items-center gap-1.5 px-2.5 py-1 text-left font-mono text-xs transition-colors ${
        current ? "text-mint" : "text-fg-muted hover:bg-bg2/70 hover:text-fg"
      }`}
    >
      <span className="w-3 shrink-0 text-center">{current ? "✓" : ""}</span>
      <span className="min-w-0 flex-1 truncate">{branch.name}</span>
    </button>
  );
}

function BranchIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3 w-3 shrink-0" fill="none" stroke="currentColor" strokeWidth="1.3">
      <circle cx="4" cy="4" r="1.7" />
      <circle cx="4" cy="12" r="1.7" />
      <circle cx="12" cy="5" r="1.7" />
      <path d="M4 5.7v4.6M12 6.7c0 2.6-4 2.3-6.3 3.6" />
    </svg>
  );
}
