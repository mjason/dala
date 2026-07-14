import React, { useEffect, useMemo, useState } from "react";
import { gitFileAt } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
import { parseDiff } from "../diffParse";
import { FileTypeIcon } from "../fileIcons";
import DiffView, { type DiffDisplayMode, type DiffSidesProvider } from "../DiffView";
import { inTextInput, Kbd } from "../shortcuts";
import Windowed from "../Windowed";
import type { DiffTarget } from "./types";

export default function DiffModal({
  target,
  onClose,
  onHunk,
}: {
  target: DiffTarget;
  onClose: () => void;
  onHunk?: (patch: string, applyTo: "index" | "workdir") => Promise<void>;
}) {
  const { t } = useI18n();
  const [mode, setMode] = useState<DiffDisplayMode>("inline");
  const [wrap, setWrap] = useState(true);
  const [onlyFile, setOnlyFile] = useState<string | null>(null);

  // Commit patches usually span several files — offer a Fork-style file rail
  // so each one can be reviewed on its own.
  const commitFiles = useMemo(
    () => (target.kind === "commit" ? parseDiff(target.text).files : []),
    [target],
  );
  useEffect(() => {
    setOnlyFile(null);
  }, [target]);

  // Fork-style per-hunk operations. Unstaged view: stage (apply forward to
  // the index — the old side IS the index, so the patch applies cleanly) or
  // discard (apply reverse to the working tree). Staged view: unstage
  // (apply reverse to the index).
  const chunkActionsFor = useMemo(() => {
    if (!onHunk || target.kind !== "file") return undefined;
    if (target.context === "unstaged") {
      return () => [
        {
          label: t("stageHunk"),
          lineLabel: t("stageLines"),
          kind: "primary" as const,
          onClick: (patch: { forward: string; reverse: string }) =>
            void onHunk(patch.forward, "index"),
        },
        {
          label: t("discardHunk"),
          lineLabel: t("discardLines"),
          kind: "danger" as const,
          onClick: (patch: { forward: string; reverse: string }, source?: "hunk" | "lines") => {
            if (!confirm(t(source === "lines" ? "discardLinesConfirm" : "discardHunkConfirm")))
              return;
            void onHunk(patch.reverse, "workdir");
          },
        },
      ];
    }
    return () => [
      {
        label: t("unstageHunk"),
        lineLabel: t("unstageLines"),
        kind: "primary" as const,
        onClick: (patch: { forward: string; reverse: string }) =>
          void onHunk(patch.reverse, "index"),
      },
    ];
  }, [onHunk, target, t]);

  const hasLineMode = chunkActionsFor !== undefined;
  const modeOptions: { value: DiffDisplayMode; label: string; key: string }[] = [
    { value: "inline", label: t("diffInline"), key: "i" },
    { value: "split", label: t("diffSplit"), key: "s" },
    ...(hasLineMode ? [{ value: "lines" as const, label: t("diffLines"), key: "l" }] : []),
  ];

  // i / s / l switch inline/split/line-select, Alt+Z toggles wrapping —
  // skipped while typing (e.g. in the diff's search panel).
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
      if (e.key === "l" && hasLineMode) setMode("lines");
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [hasLineMode]);

  // With revisions known, each file upgrades to the syntax-highlighted merge
  // view by fetching its full old/new contents; binary/oversized files (or
  // fetch failures) keep the plain hunk rendering.
  const sidesFor = useMemo<DiffSidesProvider | undefined>(() => {
    const revs = target.revs;
    if (!revs) return undefined;

    const fetchSide = async (rev: string, file: string): Promise<string> => {
      if (!file) return "";
      const result = await call<{
        content: string;
        binary: boolean;
        truncated: boolean;
        missing: boolean;
      }>(gitFileAt, {
        input: { path: revs.repo, rev, file },
        fields: ["content", "binary", "truncated", "missing"],
      });
      if (!result.ok) throw new Error("unavailable");
      const data = result.data;
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
        {modeOptions.map(({ value, label, key }) => (
          <button
            key={value}
            data-diff-mode={value}
            onClick={() => setMode(value)}
            className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 font-mono text-[11px] transition-colors ${
              mode === value ? "bg-bg2 text-mint" : "text-fg-muted hover:text-fg"
            }`}
          >
            {label} <Kbd>{key}</Kbd>
          </button>
        ))}
      </div>
      <button
        id="diff-wrap-toggle-button"
        onClick={() => setWrap((v) => !v)}
        className={`inline-flex shrink-0 items-center gap-1 rounded-md border px-2 py-0.5 font-mono text-[11px] transition-colors ${
          wrap ? "border-mint/50 text-mint" : "border-line text-fg-muted hover:text-fg"
        }`}
        title={`${t("wrapLines")} · Alt+Z`}
      >
        {t("wrapLines")} <Kbd>Alt+Z</Kbd>
      </button>
    </>
  );

  const diff = (
    <DiffView
      text={target.text}
      mode={mode}
      wrap={wrap}
      sidesFor={sidesFor}
      chunkActionsFor={chunkActionsFor}
      onlyFile={onlyFile}
    />
  );

  return (
    <Windowed id="diff-view" onClose={onClose} title={title} actions={actions}>
      {commitFiles.length > 1 ? (
        <div className="flex h-full min-h-0">
          <aside
            id="commit-file-list"
            className="w-48 shrink-0 overflow-y-auto border-r border-line bg-bg1/50 py-1 sm:w-60"
          >
            <FileRailEntry
              active={onlyFile === null}
              onClick={() => setOnlyFile(null)}
              label={t("allFiles")}
              additions={commitFiles.reduce((n, f) => n + f.additions, 0)}
              deletions={commitFiles.reduce((n, f) => n + f.deletions, 0)}
            />
            {commitFiles.map((file) => {
              const path = file.newPath || file.oldPath;
              return (
                <FileRailEntry
                  key={path}
                  active={onlyFile === path}
                  onClick={() => setOnlyFile(path)}
                  label={path}
                  icon={<FileTypeIcon name={path} />}
                  additions={file.additions}
                  deletions={file.deletions}
                />
              );
            })}
          </aside>
          <div className="min-w-0 flex-1 overflow-auto">{diff}</div>
        </div>
      ) : (
        diff
      )}
    </Windowed>
  );
}

function FileRailEntry({
  active,
  onClick,
  label,
  icon,
  additions,
  deletions,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  icon?: React.ReactNode;
  additions: number;
  deletions: number;
}) {
  return (
    <button
      data-commit-file={label}
      onClick={onClick}
      title={label}
      className={`flex w-full items-center gap-1.5 px-2.5 py-1 text-left font-mono text-[11px] transition-colors ${
        active ? "bg-bg2 text-fg" : "text-fg-muted hover:bg-bg2/60 hover:text-fg"
      }`}
    >
      {icon}
      <span className="min-w-0 flex-1 truncate" dir="rtl">
        <bdi>{label}</bdi>
      </span>
      <span className="shrink-0 text-[10px]">
        <span className="text-dala-success">+{additions}</span>{" "}
        <span className="text-danger">−{deletions}</span>
      </span>
    </button>
  );
}
