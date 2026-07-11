import React, { useEffect, useMemo, useRef, useState } from "react";
import { buildCSRFHeaders, writeFile } from "../ash_rpc";
import { humanBytes } from "./util";
import { useI18n } from "./i18n";
import { detectDelimiter, parseCsv } from "./csv";
import { rawFileUrl } from "./fileTypes";
import type { PreviewKind } from "./fileTypes";
import { FileTypeIcon } from "./fileIcons";
import Windowed from "./Windowed";
import { Kbd, modCombo } from "./shortcuts";
import CodeEditor from "./CodeEditor";
import LspDebug from "./LspDebug";
import CmCode from "./CmCode";

const CSV_MAX_ROWS = 500;
const WRAPPABLE: ReadonlySet<string> = new Set(["text", "json", "html", "csv"]);
const EDITABLE: ReadonlySet<string> = new Set(["text", "json", "html", "csv"]);

export type Preview =
  | { kind: "image" | "binary"; path: string; size: number }
  | {
      kind: Exclude<PreviewKind, "image">;
      path: string;
      size: number;
      truncated: boolean;
      content: string;
    };

type Props = {
  preview: Preview;
  onClose: () => void;
  onError: (message: string) => void;
  onSaved?: (path: string, content: string, size: number) => void;
  /** Open straight in edit mode (the drawer's row pencil). */
  startInEdit?: boolean;
};

export default function FilePreview({ preview, onClose, onError, onSaved, startInEdit }: Props) {
  const { t } = useI18n();
  const [wrap, setWrap] = useState(true);
  const [editing, setEditing] = useState(false);
  const [lspDebugOpen, setLspDebugOpen] = useState(false);
  const [draft, setDraft] = useState("");
  const [saving, setSaving] = useState(false);
  const [savedNotice, setSavedNotice] = useState(false);

  const content = "content" in preview ? preview.content : "";
  const canEdit = EDITABLE.has(preview.kind) && "truncated" in preview && !preview.truncated;
  const dirty = editing && draft !== content;

  const startEditing = () => {
    setDraft(content);
    setEditing(true);
  };

  // Row-level "edit" jumps straight into the editor once the content is in.
  const wantEdit = useRef(Boolean(startInEdit));
  useEffect(() => {
    if (wantEdit.current && canEdit && !editing) {
      wantEdit.current = false;
      startEditing();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canEdit]);

  const cancelEditing = () => {
    if (dirty && !confirm(t("discardChanges"))) return;
    setEditing(false);
  };

  const save = async () => {
    setSaving(true);
    const result = await writeFile({
      input: { path: preview.path, content: draft },
      fields: ["path", "size"],
      headers: buildCSRFHeaders(),
    });
    setSaving(false);
    if (result.success) {
      const { size } = result.data as unknown as { path: string; size: number };
      onSaved?.(preview.path, draft, size);
      setEditing(false);
      setSavedNotice(true);
      window.setTimeout(() => setSavedNotice(false), 2000);
    } else {
      onError(result.errors[0]?.message ?? t("couldNotSave"));
    }
  };

  const requestClose = () => {
    if (dirty && !confirm(t("discardChanges"))) return;
    onClose();
  };

  const stateRef = useRef({ editing, dirty, saving });
  stateRef.current = { editing, dirty, saving };

  // Alt+Z toggles wrapping (VS Code); Ctrl/Cmd+S saves while editing even
  // when the focus is outside the editor.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.altKey && !e.ctrlKey && !e.metaKey && e.code === "KeyZ") {
        e.preventDefault();
        setWrap((v) => !v);
        return;
      }
      if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "s") {
        const { editing, dirty, saving } = stateRef.current;
        if (editing) {
          e.preventDefault();
          if (dirty && !saving) void save();
        }
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const title = (
    <>
      <FileTypeIcon name={preview.path} />
      <span className="truncate font-mono text-[13px] text-fg">
        {preview.path}
        {dirty && <span className="text-[#d9a860]"> •</span>}
      </span>
      <span className="shrink-0 font-mono text-[11px] text-fg-muted">
        {humanBytes(preview.size)}
        {"truncated" in preview && preview.truncated && ` · ${t("previewTruncated")}`}
        {savedNotice && <span className="text-mint"> · {t("saved")}</span>}
      </span>
    </>
  );

  const actions = editing ? (
    <>
      <button
        id="lsp-debug-button"
        onClick={() => setLspDebugOpen(true)}
        className="shrink-0 rounded-md border border-line px-2 py-0.5 font-mono text-[11px] text-fg-muted transition-colors hover:text-fg"
        title={t("lspDebugTitle")}
      >
        {t("lspDebugOpen")}
      </button>
      <button
        id="cancel-edit-button"
        onClick={cancelEditing}
        disabled={saving}
        className="shrink-0 rounded-md border border-line px-2 py-0.5 font-mono text-[11px] text-fg-muted transition-colors hover:text-fg disabled:opacity-50"
      >
        {t("cancel")}
      </button>
      <button
        id="save-file-button"
        onClick={() => void save()}
        disabled={saving || !dirty}
        className="inline-flex shrink-0 items-center gap-1 rounded-md bg-mint px-2.5 py-0.5 font-mono text-[11px] font-medium text-black transition-colors hover:brightness-110 disabled:opacity-40"
      >
        {t("save")} <Kbd>{modCombo("s")}</Kbd>
      </button>
    </>
  ) : (
    <>
      {WRAPPABLE.has(preview.kind) && (
        <button
          id="wrap-toggle-button"
          onClick={() => setWrap((v) => !v)}
          className={`inline-flex shrink-0 items-center gap-1 rounded-md border px-2 py-0.5 font-mono text-[11px] transition-colors ${
            wrap ? "border-mint/50 text-mint" : "border-line text-fg-muted hover:text-fg"
          }`}
          title={`${t("wrapLines")} · Alt+Z`}
        >
          {t("wrapLines")} <Kbd>Alt+Z</Kbd>
        </button>
      )}
      {canEdit && (
        <button
          id="edit-file-button"
          onClick={startEditing}
          className="shrink-0 rounded-md border border-line px-2 py-0.5 font-mono text-[11px] text-fg-muted transition-colors hover:border-mint/50 hover:text-mint"
        >
          {t("edit")}
        </button>
      )}
      {preview.kind === "html" && (
        <a
          id="open-in-browser-button"
          href={rawFileUrl(preview.path)}
          target="_blank"
          rel="noopener noreferrer"
          className="shrink-0 rounded-md border border-mint/50 px-2 py-0.5 font-mono text-[11px] text-mint transition-colors hover:bg-mint/10"
        >
          {t("openInBrowser")}
        </a>
      )}
      <a
        id="download-file-button"
        href={rawFileUrl(preview.path, true)}
        className="shrink-0 rounded-md border border-line px-2 py-0.5 font-mono text-[11px] text-fg-muted transition-colors hover:text-fg"
      >
        {t("download")}
      </a>
    </>
  );

  return (
    <Windowed id="file-preview" onClose={requestClose} title={title} actions={actions}>
      {editing ? (
        <CodeEditor
          value={draft}
          onChange={setDraft}
          onSave={() => void save()}
          wrap={wrap}
          filename={preview.path}
        />
      ) : (
        <Body preview={preview} wrap={wrap} />
      )}
      {/* Stacked on top so the editor (and its LSP connections) stays alive. */}
      {lspDebugOpen && <LspDebug path={preview.path} onClose={() => setLspDebugOpen(false)} />}
    </Windowed>
  );
}

function Body({ preview, wrap }: { preview: Preview; wrap: boolean }) {
  const { t } = useI18n();

  switch (preview.kind) {
    case "image":
      return (
        <div className="grid min-h-0 flex-1 place-items-center overflow-auto bg-bg0 p-4">
          <img
            src={rawFileUrl(preview.path)}
            alt={preview.path}
            className="max-h-full max-w-full object-contain"
          />
        </div>
      );

    case "binary":
      return (
        <div className="px-4 py-10 text-center text-[13px] text-fg-muted">{t("binaryFile")}</div>
      );

    case "csv":
      return <CsvTable path={preview.path} content={preview.content} wrap={wrap} />;

    case "json":
      return <JsonView content={preview.content} wrap={wrap} />;

    // html shows its source; the "open in browser" action renders it
    case "html":
    case "text":
      return (
        <CodeView
          content={preview.content}
          fileName={preview.path}
          wrap={wrap}
          lspPath={"truncated" in preview && preview.truncated ? undefined : preview.path}
        />
      );
  }
}

function CodeView({
  content,
  fileName,
  lspPath,
  wrap,
}: {
  content: string;
  fileName: string;
  wrap: boolean;
  lspPath?: string;
}) {
  return <CmCode content={content} filename={fileName} wrap={wrap} lspPath={lspPath} />;
}

function CsvTable({ path, content, wrap }: { path: string; content: string; wrap: boolean }) {
  const { t } = useI18n();

  const rows = useMemo(() => {
    const delimiter = detectDelimiter(content, path);
    return parseCsv(content, delimiter);
  }, [content, path]);

  const [header, ...body] = rows;
  const shown = body.slice(0, CSV_MAX_ROWS);

  return (
    <div className="flex min-h-0 flex-col">
      <div className="overflow-auto">
        <table className="w-full border-collapse font-mono text-xs">
          {header && (
            <thead className="sticky top-0 bg-bg2">
              <tr>
                {header.map((cell, i) => (
                  <th
                    key={i}
                    className="border-b border-line px-2.5 py-1.5 text-left font-semibold text-fg"
                  >
                    {cell}
                  </th>
                ))}
              </tr>
            </thead>
          )}
          <tbody>
            {shown.map((row, r) => (
              <tr key={r} className="odd:bg-bg0/40">
                {row.map((cell, c) => (
                  <td
                    key={c}
                    className={`border-b border-line/50 px-2.5 py-1 text-fg-muted ${
                      wrap ? "[overflow-wrap:anywhere]" : "whitespace-nowrap"
                    }`}
                  >
                    {cell}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="border-t border-line px-3 py-1.5 font-mono text-[11px] text-fg-muted">
        {body.length > CSV_MAX_ROWS
          ? t("csvTruncatedRows", { shown: CSV_MAX_ROWS, count: body.length })
          : t("csvRows", { count: body.length })}
      </div>
    </div>
  );
}

function JsonView({ content, wrap }: { content: string; wrap: boolean }) {
  const { t } = useI18n();

  const formatted = useMemo(() => {
    try {
      return { ok: true as const, text: JSON.stringify(JSON.parse(content), null, 2) };
    } catch {
      return { ok: false as const, text: content };
    }
  }, [content]);

  return (
    <div className="flex min-h-0 flex-col">
      {!formatted.ok && (
        <div className="border-b border-line px-3 py-1.5 font-mono text-[11px] text-danger">
          {t("invalidJson")}
        </div>
      )}
      <CodeView content={formatted.text} fileName="view.json" wrap={wrap} />
    </div>
  );
}
