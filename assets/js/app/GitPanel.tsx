import React, { useCallback, useEffect, useState } from "react";
import {
  gitCheckout,
  gitCommit,
  gitDiff,
  gitDiscard,
  gitApplyPatch,
  gitLog,
  gitShow,
  gitStage,
  gitStatus,
  gitUnstage,
} from "../ash_rpc";
import type {
  GitCommitFields,
  GitDiffFields,
  GitLogFields,
  GitShowFields,
  GitStatusFields,
} from "../ash_rpc";
import { call, type RpcOutcome } from "./rpc";
import { TextArea } from "./ui";
import { useI18n } from "./i18n";
import { shortPath } from "./util";
import { hasOpenWindows, inTextInput, Tooltip } from "./shortcuts";
import ResizeHandle from "./ResizeHandle";
import type { BranchInfo, Commit, DiffContext, DiffTarget, GitFile, Status } from "./gitPanel/types";
import BranchControls from "./gitPanel/BranchControls";
import HistoryView from "./gitPanel/HistoryView";
import DiffModal from "./gitPanel/DiffModal";
import { FileRow, GroupLabel } from "./gitPanel/fileRows";

const STATUS_FIELDS = ["repo", "root", "branch", "files"] as unknown as GitStatusFields;
const LOG_FIELDS = ["commits"] as unknown as GitLogFields;
const DIFF_FIELDS: GitDiffFields = ["diff", "binary", "truncated"];
const SHOW_FIELDS: GitShowFields = ["text", "truncated"];

type Props = {
  path: string;
  onClose: () => void;
  onError: (message: string) => void;
  /** Desktop width in px (draggable via the left-edge handle). */
  width?: number;
  onResize?: (clientX: number) => void;
  onResetWidth?: () => void;
};

export default function GitPanel({
  path,
  onClose,
  onError,
  width,
  onResize,
  onResetWidth,
}: Props) {
  const { t } = useI18n();
  const [tab, setTab] = useState<"changes" | "history">("changes");
  const [status, setStatus] = useState<Status | null>(null);
  const [commits, setCommits] = useState<Commit[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [amend, setAmend] = useState(false);
  const [target, setTarget] = useState<DiffTarget | null>(null);

  const root = status?.root ?? null;

  // Escape closes the panel — unless a window (diff/preview) is on top or
  // the user is typing (commit message).
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      if (hasOpenWindows() || inTextInput(e)) return;
      e.preventDefault();
      onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const loadStatus = useCallback(async () => {
    setLoading(true);
    const result = await call<Status>(gitStatus, { input: { path }, fields: STATUS_FIELDS });
    setLoading(false);
    if (result.ok) setStatus(result.data);
    else onError(result.error || t("couldNotLoadGit"));
  }, [path, onError, t]);

  const loadLog = useCallback(async () => {
    const result = await call<{ commits: Commit[] }>(gitLog, { input: { path }, fields: LOG_FIELDS });
    if (result.ok) setCommits(result.data.commits);
    else onError(result.error || t("couldNotLoadGit"));
  }, [path, onError, t]);

  useEffect(() => {
    void loadStatus();
  }, [loadStatus]);

  useEffect(() => {
    if (tab === "history" && commits === null) void loadLog();
  }, [tab, commits, loadLog]);

  const refresh = () => {
    void loadStatus();
    if (tab === "history") void loadLog();
  };

  const run = async (key: string, fn: () => Promise<RpcOutcome<unknown>>) => {
    setBusy(key);
    const result = await fn();
    setBusy(null);
    if (!result.ok) {
      onError(result.error || t("somethingWentWrong"));
      return false;
    }
    await loadStatus();
    return true;
  };

  const openFileDiff = async (file: GitFile, context: DiffContext) => {
    if (!root) return;
    setBusy(`diff:${file.path}`);
    const result = await call<{ diff: string; binary: boolean; truncated: boolean }>(gitDiff, {
      input: { path: root, file: file.path },
      fields: DIFF_FIELDS,
    });
    setBusy(null);
    if (result.ok) {
      const data = result.data;
      // Fork's two perspectives: unstaged = index↔worktree, staged = HEAD↔index.
      const revs =
        context === "unstaged"
          ? { repo: root, oldRev: ":0", newRev: "WORKTREE" }
          : { repo: root, oldRev: "HEAD", newRev: ":0" };
      setTarget({
        kind: "file",
        title: `${file.path} · ${t(context === "unstaged" ? "changes" : "stage")}`,
        text: data.diff,
        truncated: data.truncated,
        revs,
        context,
        file,
      });
    } else {
      onError(result.error || t("couldNotLoadDiff"));
    }
  };

  // Apply a hunk patch (stage/unstage/discard), then refresh both the file
  // lists and the open diff so the remaining hunks stay accurate.
  const applyHunk = async (patch: string, applyTo: "index" | "workdir") => {
    if (!root || !target || target.kind !== "file") return;
    const result = await call<unknown>(gitApplyPatch, {
      input: { path: root, patch, target: applyTo },
      fields: ["applied"],
    });
    if (!result.ok) {
      onError(result.error || t("somethingWentWrong"));
      return;
    }
    const { file, context } = target;
    await loadStatus();
    await openFileDiff(file, context);
  };

  const openCommit = async (commit: Commit) => {
    setBusy(`show:${commit.hash}`);
    const result = await call<{ text: string; truncated: boolean }>(gitShow, {
      input: { path, hash: commit.hash },
      fields: SHOW_FIELDS,
    });
    setBusy(null);
    if (result.ok) {
      const data = result.data;
      setTarget({
        kind: "commit",
        title: `${commit.hash} · ${commit.subject}`,
        text: data.text,
        truncated: data.truncated,
        revs: { repo: path, oldRev: `${commit.hash}^`, newRev: commit.hash },
      });
    } else {
      onError(result.error || t("couldNotLoadDiff"));
    }
  };

  const commit = async () => {
    if (!root || (!message.trim() && !amend)) return;
    setBusy("commit");
    const result = await call<unknown>(gitCommit, {
      input: { path: root, message: message.trim(), amend },
      fields: ["hash"] as unknown as GitCommitFields,
    });
    setBusy(null);
    if (result.ok) {
      setMessage("");
      setAmend(false);
      setCommits(null);
      await loadStatus();
    } else {
      onError(result.error || t("couldNotCommit"));
    }
  };

  const staged = status?.files.filter((f) => f.staged) ?? [];
  const unstaged = status?.files.filter((f) => f.unstaged) ?? [];

  const switchBranch = async (branch: BranchInfo) => {
    if (branch.current) return;
    setBusy(`checkout:${branch.name}`);
    const result = await call<unknown>(gitCheckout, {
      input: { path: root ?? path, name: branch.name },
    });
    setBusy(null);
    if (result.ok) {
      // The history list belongs to the previous branch — refetch lazily.
      setCommits(null);
      await loadStatus();
    } else {
      onError(result.error || t("somethingWentWrong"));
    }
  };

  return (
    <section
      id="git-panel"
      className="fixed inset-0 z-30 flex h-full w-full shrink-0 flex-col border-l border-line bg-bg1 md:relative md:z-auto md:w-[var(--panel-w,22rem)]"
      style={width ? ({ "--panel-w": `${width}px` } as React.CSSProperties) : undefined}
    >
      {onResize && <ResizeHandle id="git-resize" edge="left" onResize={onResize} onReset={onResetWidth} />}
      <header className="flex items-center gap-2 border-b border-line px-3 py-2.5">
        <span className="text-xs font-medium uppercase tracking-wider text-fg-muted">{t("gitTitle")}</span>
        {status?.repo && status.branch && (
          <BranchControls
            path={root ?? path}
            branch={status.branch}
            onError={onError}
            onSwitch={(branch) => void switchBranch(branch)}
          />
        )}
        <div className="flex-1" />
        <button
          id="git-refresh-button"
          onClick={refresh}
          disabled={loading}
          className="grid h-6 w-6 place-items-center rounded text-fg-muted transition-colors hover:text-fg disabled:opacity-50"
          title={t("refresh")}
        >
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M13.5 8a5.5 5.5 0 1 1-1.6-3.9M13.5 1.5v3h-3" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        <Tooltip label={t("closeGitPanel")} keys="Esc">
          <button
            onClick={onClose}
            className="grid h-6 w-6 place-items-center rounded text-fg-muted transition-colors hover:text-fg"
          >
            <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
              <path d="M4 4l8 8M12 4l-8 8" strokeLinecap="round" />
            </svg>
          </button>
        </Tooltip>
      </header>

      {status && !status.repo ? (
        <div className="px-3 py-8 text-center text-[13px] text-fg-muted">{t("notARepo")}</div>
      ) : (
        <>
          <div className="flex border-b border-line px-2">
            {(["changes", "history"] as const).map((key) => (
              <button
                key={key}
                data-git-tab={key}
                onClick={() => setTab(key)}
                className={`border-b-2 px-3 py-1.5 text-xs transition-colors ${
                  tab === key
                    ? "border-mint text-fg"
                    : "border-transparent text-fg-muted hover:text-fg"
                }`}
              >
                {t(key)}
                {key === "changes" && status ? ` · ${status.files.length}` : ""}
              </button>
            ))}
          </div>

          {tab === "changes" ? (
            <>
              <div className="flex-1 overflow-y-auto py-1">
                {status?.repo && status.files.length === 0 && (
                  <div className="px-3 py-8 text-center text-[13px] text-fg-muted">{t("noChanges")}</div>
                )}
                {staged.length > 0 && (
                  <GroupLabel
                    action={{
                      id: "unstage-all-button",
                      label: t("unstageAll"),
                      onClick: () =>
                        void run("unstage-all", async () => {
                          for (const file of staged) {
                            await call<unknown>(gitUnstage, {
                              input: { path: root!, file: file.path },
                            });
                          }
                          return { ok: true, data: null };
                        }),
                    }}
                  >
                    {t("stage")}
                  </GroupLabel>
                )}
                {staged.map((file) => (
                  <FileRow
                    key={`staged:${file.path}`}
                    file={file}
                    busy={busy}
                    onOpen={() => void openFileDiff(file, "staged")}
                    actions={[
                      {
                        key: "unstage",
                        label: "−",
                        title: t("unstage"),
                        onClick: () =>
                          void run(`unstage:${file.path}`, () =>
                            call<unknown>(gitUnstage, { input: { path: root!, file: file.path } }),
                          ),
                      },
                    ]}
                  />
                ))}
                {staged.length > 0 && unstaged.length > 0 && <div className="my-1 border-t border-line/60" />}
                {unstaged.length > 0 && (
                  <GroupLabel
                    action={{
                      id: "stage-all-button",
                      label: t("stageAll"),
                      onClick: () =>
                        void run("stage-all", async () => {
                          for (const file of unstaged) {
                            await call<unknown>(gitStage, {
                              input: { path: root!, file: file.path },
                            });
                          }
                          return { ok: true, data: null };
                        }),
                    }}
                  >
                    {t("changes")}
                  </GroupLabel>
                )}
                {unstaged.map((file) => (
                  <FileRow
                    key={`unstaged:${file.path}`}
                    file={file}
                    busy={busy}
                    onOpen={() => void openFileDiff(file, "unstaged")}
                    actions={[
                      {
                        key: "discard",
                        label: "⤺",
                        title: t("discard"),
                        danger: true,
                        onClick: () => {
                          if (!confirm(t("discardConfirm", { file: file.path }))) return;
                          void run(`discard:${file.path}`, () =>
                            call<unknown>(gitDiscard, { input: { path: root!, file: file.path } }),
                          );
                        },
                      },
                      {
                        key: "stage",
                        label: "+",
                        title: t("stage"),
                        onClick: () =>
                          void run(`stage:${file.path}`, () =>
                            call<unknown>(gitStage, { input: { path: root!, file: file.path } }),
                          ),
                      },
                    ]}
                  />
                ))}
              </div>

              <div className="border-t border-line p-2">
                <TextArea
                  id="commit-message-input"
                  value={message}
                  onChange={(e) => setMessage(e.target.value)}
                  placeholder={t("commitMessage")}
                  rows={2}
                  className="resize-none"
                />
                <label className="mt-1 flex cursor-pointer select-none items-center gap-1.5 px-0.5 font-mono text-[11px] text-fg-muted">
                  <input
                    id="amend-checkbox"
                    type="checkbox"
                    checked={amend}
                    onChange={(e) => setAmend(e.target.checked)}
                    className="h-3 w-3 accent-[#4cc38a]"
                  />
                  {t("amend")}
                </label>
                <button
                  id="commit-button"
                  onClick={() => void commit()}
                  disabled={
                    busy === "commit" ||
                    (amend ? false : staged.length === 0 || !message.trim())
                  }
                  className="mt-1.5 w-full rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-black transition-colors hover:brightness-110 disabled:opacity-40"
                >
                  {amend ? t("amend") : t("commitButton")}
                  {!amend && staged.length > 0 ? ` · ${staged.length}` : ""}
                </button>
              </div>
            </>
          ) : (
            <HistoryView commits={commits} onOpen={(c) => void openCommit(c)} />
          )}
        </>
      )}

      {status?.repo && root && (
        <div className="truncate border-t border-line px-3 py-1.5 font-mono text-[11px] text-fg-muted">
          {shortPath(root, 44)}
        </div>
      )}

      {target && <DiffModal target={target} onClose={() => setTarget(null)} onHunk={applyHunk} />}
    </section>
  );
}
