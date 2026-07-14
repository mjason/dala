import React, { useEffect, useMemo, useState } from "react";
import { parseDiff, toSplitRows } from "./diffParse";
import type { DiffFile, DiffLine } from "./diffParse";
import { FileTypeIcon } from "./fileIcons";
import { useI18n } from "./i18n";
import CmDiff, { type ChunkAction } from "./CmDiff";
import LineSelectDiff from "./LineSelectDiff";

export type DiffDisplayMode = "inline" | "split" | "lines";

/**
 * Resolves the full old/new contents for one file of a diff, so the file can
 * be rendered as a syntax-highlighted merge view. Return null (or reject) to
 * keep the plain hunk-row rendering for that file.
 */
export type DiffSides = { oldText: string; newText: string };
export type DiffSidesProvider = (file: DiffFile) => Promise<DiffSides | null>;

type Props = {
  text: string;
  mode: DiffDisplayMode;
  wrap: boolean;
  sidesFor?: DiffSidesProvider;
  /** Per-hunk operations (stage/unstage/discard), given the file. */
  chunkActionsFor?: (file: DiffFile) => ChunkAction[];
  /** Restrict rendering to a single file of the diff (path as shown). */
  onlyFile?: string | null;
};

/**
 * Structured diff renderer. With a `sidesFor` provider each file upgrades to
 * a CodeMirror merge view (syntax highlighting, character-level change marks,
 * collapsed unchanged regions); without one — or while contents load, or for
 * binary files — it renders parsed hunks as colored rows.
 */
export default function DiffView({ text, mode, wrap, sidesFor, chunkActionsFor, onlyFile }: Props) {
  const parsed = useMemo(() => parseDiff(text), [text]);
  const { t } = useI18n();
  const files = onlyFile
    ? parsed.files.filter((file) => (file.newPath || file.oldPath) === onlyFile)
    : parsed.files;

  return (
    <div className="overflow-auto">
      {parsed.preamble && !onlyFile && (
        <pre className="whitespace-pre-wrap border-b border-line px-4 py-3 font-mono text-xs leading-5 text-fg-muted [overflow-wrap:anywhere]">
          {parsed.preamble}
        </pre>
      )}
      {files.map((file, i) => (
        <FileSection
          key={`${file.newPath}-${i}`}
          file={file}
          mode={mode}
          wrap={wrap}
          sidesFor={sidesFor}
          chunkActionsFor={chunkActionsFor}
          t={t}
        />
      ))}
    </div>
  );
}

function FileSection({
  file,
  mode,
  wrap,
  sidesFor,
  chunkActionsFor,
  t,
}: {
  file: DiffFile;
  mode: DiffDisplayMode;
  wrap: boolean;
  sidesFor?: DiffSidesProvider;
  chunkActionsFor?: (file: DiffFile) => ChunkAction[];
  t: (key: any) => string;
}) {
  const renamed = file.oldPath !== file.newPath && file.oldPath && file.newPath;
  const [sides, setSides] = useState<DiffSides | null>(null);

  useEffect(() => {
    if (!sidesFor || file.binary) return;

    let cancelled = false;
    sidesFor(file)
      .then((resolved) => {
        if (!cancelled) setSides(resolved);
      })
      .catch(() => undefined);

    return () => {
      cancelled = true;
    };
  }, [file, sidesFor]);

  return (
    <section className="border-b border-line last:border-b-0">
      <header className="sticky top-0 z-10 flex items-center gap-2 border-b border-line bg-bg2 px-3 py-1.5">
        <FileTypeIcon name={file.newPath || file.oldPath} />
        <span className="min-w-0 truncate font-mono text-xs text-fg">
          {renamed ? `${file.oldPath} → ${file.newPath}` : file.newPath || file.oldPath}
        </span>
        <div className="flex-1" />
        <span className="shrink-0 font-mono text-[11px]">
          <span className="text-dala-success">+{file.additions}</span>{" "}
          <span className="text-danger">−{file.deletions}</span>
        </span>
      </header>

      {file.binary ? (
        <div className="px-4 py-6 text-center font-mono text-xs text-fg-muted">
          {t("binaryDiff")}
        </div>
      ) : sides && mode === "lines" && chunkActionsFor ? (
        <LineSelectDiff
          oldText={sides.oldText}
          newText={sides.newText}
          filename={file.newPath || file.oldPath}
          wrap={wrap}
          actions={chunkActionsFor(file)}
        />
      ) : sides ? (
        <CmDiff
          oldText={sides.oldText}
          newText={sides.newText}
          mode={mode === "split" ? "split" : "inline"}
          wrap={wrap}
          filename={file.newPath || file.oldPath}
          chunkActions={chunkActionsFor?.(file)}
        />
      ) : mode === "split" ? (
        <SplitFile file={file} wrap={wrap} />
      ) : (
        <InlineFile file={file} wrap={wrap} />
      )}
    </section>
  );
}

const KIND_BG: Record<string, string> = {
  add: "bg-dala-success/[0.11]",
  del: "bg-danger/[0.10]",
  ctx: "",
};

const KIND_SIGN: Record<string, string> = { add: "+", del: "−", ctx: " " };

const KIND_SIGN_COLOR: Record<string, string> = {
  add: "text-dala-success",
  del: "text-danger",
  ctx: "text-transparent",
};

function cellText(wrap: boolean): string {
  return wrap
    ? "whitespace-pre-wrap [overflow-wrap:anywhere]"
    : "whitespace-pre";
}

function InlineFile({ file, wrap }: { file: DiffFile; wrap: boolean }) {
  return (
    <table className="w-full border-collapse font-mono text-xs leading-5">
      <tbody>
        {file.hunks.map((hunk, h) => (
          <React.Fragment key={h}>
            <tr>
              <td
                colSpan={4}
                className="bg-bg2/60 px-3 py-0.5 font-mono text-[11px] italic text-dala-cyan"
              >
                {hunk.header}
              </td>
            </tr>
            {hunk.lines.map((line, i) => (
              <tr key={i} className={KIND_BG[line.kind]}>
                <LineNo no={line.oldNo} />
                <LineNo no={line.newNo} />
                <td className={`w-4 select-none text-center ${KIND_SIGN_COLOR[line.kind]}`}>
                  {KIND_SIGN[line.kind]}
                </td>
                <td className={`w-full pr-3 text-fg ${cellText(wrap)}`}>{line.text || " "}</td>
              </tr>
            ))}
          </React.Fragment>
        ))}
      </tbody>
    </table>
  );
}

function SplitFile({ file, wrap }: { file: DiffFile; wrap: boolean }) {
  return (
    <table className="w-full table-fixed border-collapse font-mono text-xs leading-5">
      <tbody>
        {file.hunks.map((hunk, h) => (
          <React.Fragment key={h}>
            <tr>
              <td
                colSpan={4}
                className="bg-bg2/60 px-3 py-0.5 font-mono text-[11px] italic text-dala-cyan"
              >
                {hunk.header}
              </td>
            </tr>
            {toSplitRows(hunk).map((row, i) => (
              <tr key={i}>
                <SplitCell line={row.left} side="del" wrap={wrap} numberOf="old" />
                <SplitCell line={row.right} side="add" wrap={wrap} numberOf="new" />
              </tr>
            ))}
          </React.Fragment>
        ))}
      </tbody>
    </table>
  );
}

function SplitCell({
  line,
  side,
  wrap,
  numberOf,
}: {
  line: DiffLine | null;
  side: "del" | "add";
  wrap: boolean;
  numberOf: "old" | "new";
}) {
  const active = line && line.kind !== "ctx";
  const bg = active ? KIND_BG[side] : line ? "" : "bg-bg0/40";
  const no = line ? (numberOf === "old" ? line.oldNo : line.newNo) : null;

  return (
    <>
      <LineNo no={no} />
      <td className={`w-[calc(50%-3rem)] border-r border-line/40 pr-2 text-fg last:border-r-0 ${bg} ${cellText(wrap)}`}>
        {line ? line.text || " " : ""}
      </td>
    </>
  );
}

function LineNo({ no }: { no: number | null }) {
  return (
    <td className="w-10 min-w-10 select-none border-r border-line/40 px-1.5 text-right align-top text-[11px] text-fg-muted/60">
      {no ?? ""}
    </td>
  );
}
