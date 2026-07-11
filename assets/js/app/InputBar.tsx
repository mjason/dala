import React, { useEffect, useMemo, useRef, useState } from "react";
import { buildCSRFHeaders, listFiles, savePastedFile } from "../ash_rpc";
import { rankFiles } from "./fuzzy";
import { fileToBase64, pasteName } from "./pasteFiles";
import { shortPath } from "./util";
import { useI18n } from "./i18n";
import { Kbd } from "./shortcuts";

type Props = {
  /** Root for @-mention file search — the active session's cwd. */
  root: string;
  /** Foreground app in the session ("claude", "shell", …) for the placeholder. */
  app: string | null;
  onSend: (text: string, submit: boolean) => void;
  onClose: () => void;
  onError: (message: string) => void;
};

const AGENT_LABELS: Record<string, string> = {
  claude: "Claude Code",
  opencode: "opencode",
  codex: "Codex",
  gemini: "Gemini",
  copilot: "Copilot",
};

/** The `@token` currently being typed at the cursor, if any. */
function mentionAt(value: string, cursor: number): { start: number; query: string } | null {
  const before = value.slice(0, cursor);
  const match = /(^|\s)@([^\s@]*)$/.exec(before);
  if (!match) return null;
  return { start: cursor - match[2].length - 1, query: match[2] };
}

/**
 * Warp-style composer (their Ctrl-G rich input): compose locally — IME,
 * editing and cursor moves never round-trip the PTY — then deliver the
 * whole line at once. Works for plain shell commands and agent prompts;
 * `@` fuzzy-references files under the session's directory.
 */
export default function InputBar({ root, app, onSend, onClose, onError }: Props) {
  const { t } = useI18n();
  const [value, setValue] = useState("");
  const [files, setFiles] = useState<string[] | null>(null);
  const [mention, setMention] = useState<{ start: number; query: string } | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const ref = useRef<HTMLTextAreaElement>(null);
  const attachRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    ref.current?.focus();
  }, []);

  // File list loads lazily on the first `@`, once per composer open.
  useEffect(() => {
    if (!mention || files !== null) return;
    let stale = false;
    void listFiles({
      input: { path: root },
      fields: ["root", "files", "truncated"],
      headers: buildCSRFHeaders(),
    }).then((result) => {
      if (stale) return;
      if (result.success) {
        setFiles((result.data as unknown as { files: string[] }).files);
      } else {
        setFiles([]);
      }
    });
    return () => {
      stale = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mention !== null]);

  const matches = useMemo(
    () => (mention ? rankFiles(mention.query, files ?? [], 8) : []),
    [mention, files],
  );

  const syncMention = (nextValue: string, cursor: number) => {
    setMention(mentionAt(nextValue, cursor));
    setMentionIndex(0);
  };

  const pickMention = (path: string) => {
    if (!mention) return;
    // Agents understand the `@file` convention; a plain shell command wants
    // the bare path.
    const inserted = app && AGENT_LABELS[app] ? `@${path}` : path;
    const cursor = ref.current?.selectionStart ?? value.length;
    const next = `${value.slice(0, mention.start)}${inserted} ${value.slice(cursor)}`;
    setValue(next);
    setMention(null);
    requestAnimationFrame(() => {
      const pos = mention.start + inserted.length + 1;
      ref.current?.setSelectionRange(pos, pos);
      ref.current?.focus();
    });
  };

  const send = () => {
    if (!value.trim()) return;
    onSend(value, true);
    setValue("");
    setMention(null);
  };

  const attach = async (list: FileList | null) => {
    if (!list || list.length === 0) return;
    for (const file of Array.from(list)) {
      try {
        const contentBase64 = await fileToBase64(file);
        const result = await savePastedFile({
          input: { name: pasteName(file), contentBase64 },
          fields: ["path"],
          headers: buildCSRFHeaders(),
        });
        if (result.success) {
          const path = (result.data as unknown as { path: string }).path;
          setValue((v) => (v && !v.endsWith(" ") ? `${v} ${path} ` : `${v}${path} `));
        } else {
          onError(result.errors[0]?.message ?? t("uploadFailed"));
        }
      } catch {
        onError(t("uploadFailed"));
      }
    }
    ref.current?.focus();
  };

  const agentLabel = app ? AGENT_LABELS[app] : null;
  const placeholder = agentLabel
    ? t("composerAgentPlaceholder", { agent: agentLabel })
    : t("composerShellPlaceholder");

  return (
    <div id="input-bar" className="relative shrink-0 border-t border-line bg-bg1 px-3 pt-2 pb-1.5">
      {mention && matches.length > 0 && (
        <div
          id="mention-menu"
          className="absolute bottom-full left-3 z-10 mb-1 max-h-64 w-[32rem] max-w-[90%] overflow-y-auto rounded-lg border border-line bg-bg1 py-1 shadow-2xl shadow-black/50"
        >
          {matches.map((m, i) => (
            <button
              key={m.path}
              data-mention-item={m.path}
              onMouseDown={(e) => {
                e.preventDefault();
                pickMention(m.path);
              }}
              className={`block w-full truncate px-3 py-1 text-left font-mono text-[13px] ${
                i === mentionIndex ? "bg-bg2 text-mint" : "text-fg-muted hover:text-fg"
              }`}
            >
              {m.path}
            </button>
          ))}
        </div>
      )}

      <textarea
        ref={ref}
        id="input-bar-textarea"
        value={value}
        onChange={(e) => {
          setValue(e.target.value);
          syncMention(e.target.value, e.target.selectionStart ?? e.target.value.length);
        }}
        onKeyDown={(e) => {
          if (mention && matches.length > 0) {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setMentionIndex((i) => Math.min(i + 1, matches.length - 1));
              return;
            }
            if (e.key === "ArrowUp") {
              e.preventDefault();
              setMentionIndex((i) => Math.max(i - 1, 0));
              return;
            }
            if (e.key === "Tab" || (e.key === "Enter" && !e.nativeEvent.isComposing)) {
              e.preventDefault();
              pickMention(matches[mentionIndex].path);
              return;
            }
            if (e.key === "Escape") {
              e.preventDefault();
              setMention(null);
              return;
            }
          }
          if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
            e.preventDefault();
            send();
            return;
          }
          if (e.key === "Escape") {
            e.preventDefault();
            onClose();
          }
        }}
        onClick={(e) => {
          const el = e.currentTarget;
          syncMention(el.value, el.selectionStart ?? el.value.length);
        }}
        placeholder={placeholder}
        rows={Math.min(6, Math.max(1, value.split("\n").length))}
        spellCheck={false}
        className="max-h-40 w-full resize-none rounded-md border border-line bg-bg0 px-3 py-1.5 font-mono text-[14px] leading-6 text-fg outline-none transition-colors placeholder:text-fg-muted/50 focus:border-mint/60"
      />

      <div className="mt-1 flex items-center gap-2">
        <button
          id="input-bar-send"
          onClick={send}
          disabled={!value.trim()}
          className="inline-flex shrink-0 items-center gap-1.5 rounded-md bg-mint px-2.5 py-1 text-[12px] font-medium text-black transition-all hover:brightness-110 active:scale-[0.98] disabled:opacity-40"
        >
          {t("inputBarSend")} <Kbd>⏎</Kbd>
        </button>
        <button
          id="input-bar-mention"
          onClick={() => {
            const el = ref.current;
            if (!el) return;
            const cursor = el.selectionStart ?? value.length;
            const prefix = value.slice(0, cursor);
            const inject = prefix === "" || prefix.endsWith(" ") ? "@" : " @";
            const next = value.slice(0, cursor) + inject + value.slice(cursor);
            setValue(next);
            requestAnimationFrame(() => {
              el.setSelectionRange(cursor + inject.length, cursor + inject.length);
              el.focus();
              syncMention(next, cursor + inject.length);
            });
          }}
          className="shrink-0 rounded-md border border-line px-2 py-1 font-mono text-[12px] text-fg-muted transition-colors hover:border-mint/60 hover:text-mint"
          title={t("composerMention")}
        >
          @
        </button>
        <button
          id="input-bar-attach"
          onClick={() => attachRef.current?.click()}
          className="grid h-6 w-6 shrink-0 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:border-mint/60 hover:text-mint"
          title={t("composerAttach")}
        >
          <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M8 3v10M3 8h10" strokeLinecap="round" />
          </svg>
        </button>
        <input
          ref={attachRef}
          type="file"
          multiple
          className="hidden"
          onChange={(e) => {
            void attach(e.target.files);
            e.target.value = "";
          }}
        />
        {agentLabel && (
          <span className="rounded-full bg-mint/10 px-2 py-0.5 font-mono text-[11px] text-mint">
            {agentLabel}
          </span>
        )}
        <div className="flex-1" />
        <span className="hidden truncate font-mono text-[11px] text-fg-muted/60 sm:block" title={root}>
          {shortPath(root, 40)}
        </span>
        <span className="hidden shrink-0 items-center gap-1 font-mono text-[11px] text-fg-muted/60 sm:inline-flex">
          {t("composerHide")} <Kbd>^G</Kbd>
        </span>
      </div>
    </div>
  );
}
