import React, { useEffect, useRef, useState } from "react";
import {
  archivePrompt,
  deletePrompt,
  listPrompts,
  restorePrompt,
  stashPrompt,
} from "../ash_rpc";
import { call } from "./rpc";
import { useI18n } from "./i18n";

/**
 * The prompt stash: quick capture of prompts/ideas, quick recall in the
 * composer. Clicking a stashed entry inserts it AND archives it (the stash
 * is a to-use queue; the archive below is its history). Entries can also
 * arrive from anywhere via the MCP `stash_prompt` tool.
 */

type PromptRow = { id: string; content: string; status: "stashed" | "archived" };

type Props = {
  /** Current composer text (to stash, and to append into). */
  value: string;
  setValue: (next: string) => void;
  onError: (message: string) => void;
  /** Published so the composer's keyboard shortcut can stash without the mouse. */
  stashActionRef?: React.MutableRefObject<(() => void) | null>;
  /** Formatted key combo shown in tooltips/buttons. */
  shortcutHint?: string;
};

export default function PromptStash({
  value,
  setValue,
  onError,
  stashActionRef,
  shortcutHint,
}: Props) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<PromptRow[] | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);

  const refresh = async () => {
    const result = await call<PromptRow[]>(listPrompts, {
      fields: ["id", "content", "status"],
    });
    if (!result.ok) return onError(result.error || t("somethingWentWrong"));
    setRows(result.data);
  };

  useEffect(() => {
    if (open) void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  // Click-away / Escape close the panel.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!panelRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      e.preventDefault();
      setOpen(false);
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [open]);

  const stashCurrent = async () => {
    const content = value.trim();
    if (!content) return;
    const result = await call<unknown>(stashPrompt, { input: { content }, fields: ["id"] });
    if (!result.ok) return onError(result.error || t("somethingWentWrong"));
    setValue("");
    await refresh();
  };

  const insert = (content: string) => {
    setValue(value.trim() === "" ? content : `${value}\n${content}`);
    setOpen(false);
  };

  const use = async (row: PromptRow) => {
    insert(row.content);
    // Consuming a stashed prompt archives it; re-using an archived one
    // leaves the archive untouched.
    if (row.status !== "stashed") return;
    const result = await call<unknown>(archivePrompt, { identity: row.id, fields: ["id"] });
    if (!result.ok) onError(result.error || t("somethingWentWrong"));
  };

  const restore = async (id: string) => {
    const result = await call<unknown>(restorePrompt, { identity: id, fields: ["id"] });
    if (!result.ok) return onError(result.error || t("somethingWentWrong"));
    await refresh();
  };

  const remove = async (id: string) => {
    const result = await call<unknown>(deletePrompt, { identity: id, fields: ["id"] });
    if (!result.ok) return onError(result.error || t("somethingWentWrong"));
    await refresh();
  };

  // Keyboard path (composerStash): stash whatever is in the composer now.
  useEffect(() => {
    if (!stashActionRef) return;
    stashActionRef.current = () => void stashCurrent();
    return () => {
      stashActionRef.current = null;
    };
  });

  const stashed = (rows ?? []).filter((r) => r.status === "stashed");
  const archived = (rows ?? []).filter((r) => r.status === "archived");

  const row = (r: PromptRow) => (
    <div
      key={r.id}
      data-prompt-row={r.id}
      onClick={() => void use(r)}
      title={`${r.content.length > 400 ? r.content.slice(0, 400) + "…" : r.content}\n\n${t("promptInsertHint")}`}
      className={`group flex cursor-pointer items-center gap-1 py-1.5 pl-3 pr-2 transition-colors hover:bg-bg2 ${
        r.status === "archived" ? "opacity-60" : ""
      }`}
    >
      <div className="min-w-0 flex-1 truncate font-mono text-xs leading-5 text-fg">
        {r.content.split("\n")[0]}
      </div>
      {r.status === "archived" && (
        <button
          data-prompt-restore={r.id}
          onClick={(e) => {
            e.stopPropagation();
            void restore(r.id);
          }}
          title={t("restore")}
          className="hidden h-5 w-5 shrink-0 place-items-center rounded text-fg-muted transition-colors group-hover:grid hover:text-mint"
        >
          <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M3 8a5 5 0 1 0 1.5-3.5M4.5 1.5v3h3" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      )}
      <button
        data-prompt-delete={r.id}
        onClick={(e) => {
          e.stopPropagation();
          void remove(r.id);
        }}
        title={t("deleteEntry")}
        className="hidden h-5 w-5 shrink-0 place-items-center rounded text-fg-muted transition-colors group-hover:grid hover:text-danger"
      >
        <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
          <path d="m4 4 8 8m0-8-8 8" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  );

  return (
    <div ref={panelRef} className="relative">
      <button
        id="prompt-stash-button"
        onClick={() => setOpen((v) => !v)}
        className={`grid h-6 w-6 shrink-0 place-items-center rounded-md border transition-colors pointer-coarse:h-10 pointer-coarse:w-10 ${
          open ? "border-mint/50 text-mint" : "border-line text-fg-muted hover:border-mint/60 hover:text-mint"
        }`}
        title={shortcutHint ? `${t("promptStash")} · ${shortcutHint}` : t("promptStash")}
      >
        <svg viewBox="0 0 16 16" className="h-3 w-3 pointer-coarse:h-4 pointer-coarse:w-4" fill="none" stroke="currentColor" strokeWidth="1.5">
          <path d="M4 2.5h8a.5.5 0 0 1 .5.5v10.2a.3.3 0 0 1-.47.25L8 11l-4.03 2.45a.3.3 0 0 1-.47-.25V3a.5.5 0 0 1 .5-.5Z" strokeLinejoin="round" />
        </svg>
      </button>

      {open && (
        <div
          id="prompt-stash-panel"
          className="absolute bottom-full left-0 z-40 mb-2 w-80 overflow-hidden rounded-lg border border-line bg-bg1 shadow-xl shadow-black/40"
        >
          <div className="flex items-center justify-between gap-2 border-b border-line px-3 py-2">
            <span className="text-xs font-medium text-fg">{t("promptStash")}</span>
            <button
              id="stash-current-button"
              disabled={!value.trim()}
              onClick={() => void stashCurrent()}
              title={shortcutHint ? `${t("stashCurrentInput")} · ${shortcutHint}` : undefined}
              className="rounded-md bg-mint/10 px-2 py-1 text-[11px] font-medium text-mint transition-colors hover:bg-mint/20 disabled:opacity-40"
            >
              {t("stashCurrentInput")}
            </button>
          </div>

          <div className="max-h-72 overflow-y-auto py-1">
            {rows != null && stashed.length === 0 && archived.length === 0 && (
              <div className="px-3 py-3 text-center text-xs leading-5 text-fg-muted">
                {t("promptStashEmpty")}
              </div>
            )}
            {stashed.map(row)}
            {archived.length > 0 && (
              <>
                <div className="mt-1 border-t border-line px-3 pt-2 pb-1 text-[10px] font-medium tracking-wide text-fg-muted/70 uppercase">
                  {t("promptArchived")}
                </div>
                {archived.map(row)}
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
