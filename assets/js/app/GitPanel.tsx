import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  buildCSRFHeaders,
  gitCommit,
  gitDiff,
  gitDiscard,
  gitFileAt,
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
import { useI18n } from "./i18n";
import { shortPath } from "./util";
import { FileTypeIcon } from "./fileIcons";
import DiffView, { type DiffDisplayMode, type DiffSidesProvider } from "./DiffView";
import { hasOpenWindows, inTextInput, Kbd, Tooltip } from "./shortcuts";
import Windowed from "./Windowed";

const STATUS_FIELDS = ["repo", "root", "branch", "files"] as unknown as GitStatusFields;
const LOG_FIELDS = ["commits"] as unknown as GitLogFields;
const DIFF_FIELDS: GitDiffFields = ["diff", "binary", "truncated"];
const SHOW_FIELDS: GitShowFields = ["text", "truncated"];

type GitFile = { path: string; status: string; staged: boolean };
type Status = { repo: boolean; root: string | null; branch: string | null; files: GitFile[] };
type Commit = { hash: string; author: string; date: string; subject: string };

/** Revisions to fetch full file contents from, powering the merge view. */
type DiffRevs = { repo: string; oldRev: string; newRev: string };

type DiffTarget =
  | { kind: "file"; title: string; text: string; truncated: boolean; revs?: DiffRevs }
  | { kind: "commit"; title: string; text: string; truncated: boolean; revs?: DiffRevs };

type Props = {
  path: string;
  onClose: () => void;
  onError: (message: string) => void;
};

export default function GitPanel({ path, onClose, onError }: Props) {
  const { t } = useI18n();
  const [tab, setTab] = useState<"changes" | "history">("changes");
  const [status, setStatus] = useState<Status | null>(null);
  const [commits, setCommits] = useState<Commit[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState("");
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
    const result = await gitStatus({ input: { path }, fields: STATUS_FIELDS, headers: buildCSRFHeaders() });
    setLoading(false);
    if (result.success) setStatus(result.data as unknown as Status);
    else onError(result.errors[0]?.message ?? t("couldNotLoadGit"));
  }, [path, onError, t]);

  const loadLog = useCallback(async () => {
    const result = await gitLog({ input: { path }, fields: LOG_FIELDS, headers: buildCSRFHeaders() });
    if (result.success) setCommits((result.data as unknown as { commits: Commit[] }).commits);
    else onError(result.errors[0]?.message ?? t("couldNotLoadGit"));
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

  const run = async (key: string, fn: () => Promise<{ success: boolean; errors?: any }>) => {
    setBusy(key);
    const result = await fn();
    setBusy(null);
    if (!result.success) {
      onError(result.errors?.[0]?.message ?? t("somethingWentWrong"));
      return false;
    }
    await loadStatus();
    return true;
  };

  const openFileDiff = async (file: GitFile) => {
    if (!root) return;
    setBusy(`diff:${file.path}`);
    const result = await gitDiff({
      input: { path: root, file: file.path },
      fields: DIFF_FIELDS,
      headers: buildCSRFHeaders(),
    });
    setBusy(null);
    if (result.success) {
      const data = result.data as unknown as { diff: string; binary: boolean; truncated: boolean };
      setTarget({
        kind: "file",
        title: file.path,
        text: data.diff,
        truncated: data.truncated,
        revs: { repo: root, oldRev: "HEAD", newRev: "WORKTREE" },
      });
    } else {
      onError(result.errors[0]?.message ?? t("couldNotLoadDiff"));
    }
  };

  const openCommit = async (commit: Commit) => {
    setBusy(`show:${commit.hash}`);
    const result = await gitShow({
      input: { path, hash: commit.hash },
      fields: SHOW_FIELDS,
      headers: buildCSRFHeaders(),
    });
    setBusy(null);
    if (result.success) {
      const data = result.data as unknown as { text: string; truncated: boolean };
      setTarget({
        kind: "commit",
        title: `${commit.hash} · ${commit.subject}`,
        text: data.text,
        truncated: data.truncated,
        revs: { repo: path, oldRev: `${commit.hash}^`, newRev: commit.hash },
      });
    } else {
      onError(result.errors[0]?.message ?? t("couldNotLoadDiff"));
    }
  };

  const commit = async () => {
    if (!root || !message.trim()) return;
    setBusy("commit");
    const result = await gitCommit({
      input: { path: root, message: message.trim() },
      fields: ["hash"] as unknown as GitCommitFields,
      headers: buildCSRFHeaders(),
    });
    setBusy(null);
    if (result.success) {
      setMessage("");
      setCommits(null);
      await loadStatus();
    } else {
      onError(result.errors[0]?.message ?? t("couldNotCommit"));
    }
  };

  const staged = status?.files.filter((f) => f.staged) ?? [];
  const unstaged = status?.files.filter((f) => !f.staged) ?? [];

  return (
    <section
      id="git-panel"
      className="fixed inset-0 z-30 flex h-full w-full shrink-0 flex-col border-l border-line bg-bg1 md:static md:z-auto md:w-[22rem]"
    >
      <header className="flex items-center gap-2 border-b border-line px-3 py-2.5">
        <span className="text-xs font-medium uppercase tracking-wider text-fg-muted">{t("gitTitle")}</span>
        {status?.repo && status.branch && (
          <span className="flex min-w-0 items-center gap-1 font-mono text-xs text-mint">
            <BranchIcon />
            <span className="truncate">{status.branch}</span>
          </span>
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
                  <GroupLabel>{t("stage")}</GroupLabel>
                )}
                {staged.map((file) => (
                  <FileRow
                    key={file.path}
                    file={file}
                    busy={busy}
                    onOpen={() => void openFileDiff(file)}
                    actions={[
                      {
                        key: "unstage",
                        label: "−",
                        title: t("unstage"),
                        onClick: () =>
                          void run(`unstage:${file.path}`, () =>
                            gitUnstage({ input: { path: root!, file: file.path }, headers: buildCSRFHeaders() }),
                          ),
                      },
                    ]}
                  />
                ))}
                {staged.length > 0 && unstaged.length > 0 && <div className="my-1 border-t border-line/60" />}
                {unstaged.map((file) => (
                  <FileRow
                    key={file.path}
                    file={file}
                    busy={busy}
                    onOpen={() => void openFileDiff(file)}
                    actions={[
                      {
                        key: "discard",
                        label: "⤺",
                        title: t("discard"),
                        danger: true,
                        onClick: () => {
                          if (!confirm(t("discardConfirm", { file: file.path }))) return;
                          void run(`discard:${file.path}`, () =>
                            gitDiscard({ input: { path: root!, file: file.path }, headers: buildCSRFHeaders() }),
                          );
                        },
                      },
                      {
                        key: "stage",
                        label: "+",
                        title: t("stage"),
                        onClick: () =>
                          void run(`stage:${file.path}`, () =>
                            gitStage({ input: { path: root!, file: file.path }, headers: buildCSRFHeaders() }),
                          ),
                      },
                    ]}
                  />
                ))}
              </div>

              <div className="border-t border-line p-2">
                <textarea
                  id="commit-message-input"
                  value={message}
                  onChange={(e) => setMessage(e.target.value)}
                  placeholder={t("commitMessage")}
                  rows={2}
                  className="w-full resize-none rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[13px] text-fg outline-none transition-colors placeholder:text-fg-muted/60 focus:border-mint/60"
                />
                <button
                  id="commit-button"
                  onClick={() => void commit()}
                  disabled={busy === "commit" || staged.length === 0 || !message.trim()}
                  className="mt-1.5 w-full rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-black transition-colors hover:brightness-110 disabled:opacity-40"
                >
                  {t("commitButton")}
                  {staged.length > 0 ? ` · ${staged.length}` : ""}
                </button>
              </div>
            </>
          ) : (
            <div id="git-history" className="flex-1 overflow-y-auto py-1">
              {commits?.length === 0 && (
                <div className="px-3 py-8 text-center text-[13px] text-fg-muted">{t("noChanges")}</div>
              )}
              {commits?.map((c) => (
                <button
                  key={c.hash}
                  onClick={() => void openCommit(c)}
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
          )}
        </>
      )}

      {status?.repo && root && (
        <div className="truncate border-t border-line px-3 py-1.5 font-mono text-[11px] text-fg-muted">
          {shortPath(root, 44)}
        </div>
      )}

      {target && <DiffModal target={target} onClose={() => setTarget(null)} />}
    </section>
  );
}

function GroupLabel({ children }: { children: React.ReactNode }) {
  return (
    <div className="px-3 pb-0.5 pt-1.5 font-mono text-[10px] uppercase tracking-wider text-fg-muted/70">
      {children}
    </div>
  );
}

type RowAction = {
  key: string;
  label: string;
  title: string;
  danger?: boolean;
  onClick: () => void;
};

function FileRow({
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
  const code = status === "??" ? "?" : status.trim().slice(0, 1) || "·";
  const color = useMemo(() => {
    switch (code) {
      case "A":
      case "?":
        return "text-mint";
      case "M":
        return "text-[#d9a860]";
      case "D":
        return "text-danger";
      case "R":
      case "C":
        return "text-[#6d9fd6]";
      default:
        return "text-fg-muted";
    }
  }, [code]);

  return (
    <span className={`w-4 shrink-0 text-center font-mono text-xs font-semibold ${color}`}>{code}</span>
  );
}

function DiffModal({ target, onClose }: { target: DiffTarget; onClose: () => void }) {
  const { t } = useI18n();
  const [mode, setMode] = useState<DiffDisplayMode>("inline");
  const [wrap, setWrap] = useState(true);

  // i / s switch inline/split, Alt+Z toggles wrapping — skipped while typing
  // (e.g. in the diff's search panel).
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      if (e.altKey && !e.ctrlKey && !e.metaKey && e.code === "KeyZ") {
        e.preventDefault();
        setWrap((v) => !v);
        return;
      }
      if (e.ctrlKey || e.metaKey || e.altKey || inTextInput(e)) return;
      if (e.key === "i") setMode("inline");
      if (e.key === "s") setMode("split");
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  // With revisions known, each file upgrades to the syntax-highlighted merge
  // view by fetching its full old/new contents; binary/oversized files (or
  // fetch failures) keep the plain hunk rendering.
  const sidesFor = useMemo<DiffSidesProvider | undefined>(() => {
    const revs = target.revs;
    if (!revs) return undefined;

    const fetchSide = async (rev: string, file: string): Promise<string> => {
      if (!file) return "";
      const result = await gitFileAt({
        input: { path: revs.repo, rev, file },
        fields: ["content", "binary", "truncated", "missing"],
        headers: buildCSRFHeaders(),
      });
      if (!result.success) throw new Error("unavailable");
      const data = result.data as unknown as {
        content: string;
        binary: boolean;
        truncated: boolean;
        missing: boolean;
      };
      if (data.binary || data.truncated) throw new Error("not renderable");
      return data.missing ? "" : data.content;
    };

    return async (file) => {
      try {
        const [oldText, newText] = await Promise.all([
          fetchSide(revs.oldRev, file.oldPath),
          fetchSide(revs.newRev, file.newPath),
        ]);
        return { oldText, newText };
      } catch {
        return null;
      }
    };
  }, [target]);

  const title = (
    <span className="truncate font-mono text-[13px] text-fg">{target.title}</span>
  );

  const actions = (
    <>
      {target.truncated && (
        <span className="shrink-0 font-mono text-[11px] text-fg-muted">{t("diffTruncated")}</span>
      )}
      <div className="hidden shrink-0 items-center gap-0.5 rounded-md border border-line p-0.5 sm:flex">
        {(["inline", "split"] as const).map((value) => (
          <button
            key={value}
            data-diff-mode={value}
            onClick={() => setMode(value)}
            className={`rounded px-1.5 py-0.5 font-mono text-[11px] transition-colors ${
              mode === value ? "bg-bg2 text-mint" : "text-fg-muted hover:text-fg"
            }`}
          >
            {value === "inline" ? t("diffInline") : t("diffSplit")}{" "}
            <Kbd>{value === "inline" ? "i" : "s"}</Kbd>
          </button>
        ))}
      </div>
      <button
        id="diff-wrap-toggle-button"
        onClick={() => setWrap((v) => !v)}
        className={`shrink-0 rounded-md border px-2 py-0.5 font-mono text-[11px] transition-colors ${
          wrap ? "border-mint/50 text-mint" : "border-line text-fg-muted hover:text-fg"
        }`}
        title={`${t("wrapLines")} · Alt+Z`}
      >
        {t("wrapLines")} <Kbd>Alt+Z</Kbd>
      </button>
    </>
  );

  return (
    <Windowed id="diff-view" onClose={onClose} title={title} actions={actions}>
      <DiffView text={target.text} mode={mode} wrap={wrap} sidesFor={sidesFor} />
    </Windowed>
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

function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
