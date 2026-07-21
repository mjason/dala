import React, { useEffect, useMemo, useRef, useState } from "react";
import { listFiles } from "../ash_rpc";
import { call } from "./rpc";
import { rankFiles } from "./fuzzy";
import { FileTypeIcon } from "./fileIcons";
import { useI18n } from "./i18n";
import { KeyHint } from "./shortcuts";
import { isAbsoluteHost, joinHost } from "./hostPath";

type Props = {
  root: string;
  onPick: (absolutePath: string) => void;
  onClose: () => void;
  onError: (message: string) => void;
};

/**
 * VS Code-style Ctrl+P palette: the file list under `root` is fetched once
 * on open, then fuzzy-filtered locally as you type.
 */
export default function QuickOpen({ root, onPick, onClose, onError }: Props) {
  const { t } = useI18n();
  const [files, setFiles] = useState<string[] | null>(null);
  const [truncated, setTruncated] = useState(false);
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let stale = false;

    void call<{ root: string; files: string[]; truncated: boolean }>(listFiles, {
      input: { path: root },
      fields: ["root", "files", "truncated"],
    }).then((result) => {
      if (stale) return;
      if (result.ok) {
        setFiles(result.data.files);
        setTruncated(result.data.truncated);
      } else {
        onError(result.error || t("somethingWentWrong"));
        onClose();
      }
    });

    return () => {
      stale = true;
    };
    // Loaded once per palette open.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [root]);

  const ranked = useMemo(() => rankFiles(query, files ?? [], 100, root), [query, files, root]);

  // A path-like query (absolute, or containing a "/") can open a file DIRECTLY
  // by its exact path — including one the fuzzy index never lists because its
  // directory is git-ignored. Shown as a trailing entry; when nothing fuzzy
  // matches (the ignored-file case) it is the only, auto-selected row.
  const trimmed = query.trim();
  const directTarget = !/[\\/]/.test(trimmed)
    ? null
    : isAbsoluteHost(trimmed)
      ? trimmed
      : joinHost(root, trimmed);

  const total = ranked.length + (directTarget ? 1 : 0);
  const active = Math.min(index, Math.max(0, total - 1));
  const directActive = directTarget != null && active === ranked.length;

  useEffect(() => setIndex(0), [query]);

  useEffect(() => {
    listRef.current
      ?.querySelector('[aria-selected="true"]')
      ?.scrollIntoView?.({ block: "nearest" });
  }, [index, ranked]);

  const pick = (relative: string) => {
    onPick(joinHost(root, relative));
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        setIndex((i) => Math.min(total - 1, i + 1));
        break;
      case "ArrowUp":
        e.preventDefault();
        setIndex((i) => Math.max(0, i - 1));
        break;
      case "Enter":
        e.preventDefault();
        if (directActive && directTarget) onPick(directTarget);
        else if (ranked[active]) pick(ranked[active].path);
        break;
      case "Escape":
        e.preventDefault();
        onClose();
        break;
    }
  };

  return (
    <div
      className="fixed inset-0 z-40 flex justify-center bg-black/50 p-4 pt-[10vh]"
      onClick={onClose}
    >
      <div
        id="quick-open"
        className="flex h-fit max-h-[70vh] w-full max-w-xl flex-col overflow-hidden rounded-xl border border-line bg-bg1 shadow-2xl"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={onKeyDown}
      >
        <div className="flex items-center gap-2 border-b border-line px-3 py-2.5">
          <SearchIcon />
          <input
            id="quick-open-input"
            ref={inputRef}
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t("quickOpenPlaceholder")}
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
            className="min-w-0 flex-1 bg-transparent font-mono text-[13px] text-fg outline-none placeholder:text-fg-muted/60"
          />
          {truncated && (
            <span className="shrink-0 font-mono text-[10px] text-fg-muted">
              {t("quickOpenTruncated")}
            </span>
          )}
        </div>

        <div ref={listRef} id="quick-open-results" className="min-h-0 overflow-y-auto py-1">
          {files === null && (
            <div className="px-3 py-3 text-center font-mono text-xs text-fg-muted">…</div>
          )}
          {files !== null && total === 0 && (
            <div className="px-3 py-3 text-center font-mono text-xs text-fg-muted">
              {t("quickOpenEmpty")}
            </div>
          )}
          {ranked.map((match, i) => (
            <div
              key={match.path}
              role="option"
              aria-selected={i === active}
              data-quick-path={match.path}
              onClick={() => pick(match.path)}
              onMouseMove={() => setIndex(i)}
              className={`flex cursor-pointer items-center gap-2 px-3 py-1.5 ${
                i === active ? "bg-bg2" : ""
              }`}
            >
              <FileTypeIcon name={match.display} />
              {/* Highlights index the NFC display form, never the raw path. */}
              <HighlightedPath path={match.display} positions={match.positions} />
            </div>
          ))}
          {directTarget && (
            <div
              role="option"
              aria-selected={directActive}
              data-quick-direct-path={directTarget}
              onClick={() => onPick(directTarget)}
              onMouseMove={() => setIndex(ranked.length)}
              className={`flex cursor-pointer items-center gap-2 px-3 py-1.5 ${
                directActive ? "bg-bg2" : ""
              }`}
            >
              <FileTypeIcon name={directTarget} />
              <span
                className="min-w-0 flex-1 truncate font-mono text-[13px] text-fg"
                title={directTarget}
              >
                {directTarget}
              </span>
              <span className="shrink-0 rounded border border-line px-1.5 py-0.5 font-mono text-[10px] text-fg-muted">
                {t("quickOpenByPath")}
              </span>
            </div>
          )}
        </div>

        <footer className="flex items-center gap-3 border-t border-line px-3 py-1.5 font-mono text-[10px] text-fg-muted/70">
          <KeyHint keys="↑↓" label={t("hintSelect")} />
          <KeyHint keys="⏎" label={t("hintOpen")} />
          <KeyHint keys="Esc" label={t("cancel")} />
        </footer>
      </div>
    </div>
  );
}

function HighlightedPath({ path, positions }: { path: string; positions: number[] }) {
  const marks = new Set(positions);
  const slash = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));

  // `positions` are code-unit indices (they come from indexOf), so iterate
  // code units — Array.from iterates code points and would shift everything
  // after an emoji. Consecutive units with the same style are grouped into
  // one span so surrogate pairs are never split across elements.
  const runs: { text: string; className: string }[] = [];
  for (let i = 0; i < path.length; i++) {
    const className = marks.has(i)
      ? "font-semibold text-mint"
      : i <= slash
        ? "text-fg-muted"
        : "text-fg";
    const last = runs[runs.length - 1];
    if (last && last.className === className) last.text += path[i];
    else runs.push({ text: path[i], className });
  }

  return (
    <span className="min-w-0 flex-1 truncate font-mono text-[13px]" title={path}>
      {runs.map((run, i) => (
        <span key={i} className={run.className}>
          {run.text}
        </span>
      ))}
    </span>
  );
}

function SearchIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      className="h-3.5 w-3.5 shrink-0 text-fg-muted"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
    >
      <circle cx="7" cy="7" r="4" />
      <path d="m13 13-3.2-3.2" strokeLinecap="round" />
    </svg>
  );
}
