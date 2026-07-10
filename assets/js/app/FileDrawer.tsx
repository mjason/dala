import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { buildCSRFHeaders, deleteEntry, listDirectory } from "../ash_rpc";
import type { ListDirectoryFields } from "../ash_rpc";
import { humanBytes, writeClipboard } from "./util";
import { useI18n } from "./i18n";
import FilePreview, { type Preview } from "./FilePreview";
import { loadPreview } from "./loadPreview";
import { rawFileUrl } from "./fileTypes";
import { FileTypeIcon } from "./fileIcons";
import { collectTransferFiles } from "./pasteFiles";
import { Kbd, KeyHint, modLabel } from "./shortcuts";
import ResizeHandle from "./ResizeHandle";

// "entries" as a leaf field returns the full entry maps; the generated
// selection type has no shape for arrays of typed maps, hence the cast.
const DIR_FIELDS = ["path", "parent", "entries"] as unknown as ListDirectoryFields;


export type Entry = {
  name: string;
  type: string;
  symlink: boolean;
  size: number;
  mtime: string | null;
};

type Listing = {
  path: string;
  parent: string | null;
  entries: Entry[];
};

type TreeRow =
  | { kind: "up"; path: string }
  | { kind: "dir" | "file"; path: string; entry: Entry; depth: number; parentDir: string }
  | { kind: "note"; id: string; text: string; depth: number };

type SelectableRow = Exclude<TreeRow, { kind: "note" }>;

type DeleteTarget = { path: string; isDir: boolean; parentDir: string };

type Props = {
  path: string;
  followCwd: boolean;
  onNavigate: (path: string) => void;
  onToggleFollow: () => void;
  onClose: () => void;
  onError: (message: string) => void;
  /** Desktop width in px (draggable via the left-edge handle). */
  width?: number;
  onResize?: (clientX: number) => void;
  onResetWidth?: () => void;
};

function join(dir: string, name: string): string {
  return `${dir === "/" ? "" : dir}/${name}`;
}

/** VS Code-style relative path from the drawer root to a target. */
function relativePath(from: string, to: string): string {
  const f = from.split("/").filter(Boolean);
  const s = to.split("/").filter(Boolean);
  let i = 0;
  while (i < f.length && i < s.length && f[i] === s[i]) i++;
  const parts = [...Array(f.length - i).fill(".."), ...s.slice(i)];
  return parts.length ? parts.join("/") : ".";
}

export default function FileDrawer({
  path,
  followCwd,
  onNavigate,
  onToggleFollow,
  onClose,
  onError,
  width,
  onResize,
  onResetWidth,
}: Props) {
  const { t } = useI18n();
  const [root, setRoot] = useState<Listing | null>(null);
  const [children, setChildren] = useState<Record<string, Entry[]>>({});
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [loadingDirs, setLoadingDirs] = useState<Set<string>>(new Set());
  const [showHidden, setShowHidden] = useState(false);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [editOnOpen, setEditOnOpen] = useState(false);
  const [previewLoading, setPreviewLoading] = useState<string | null>(null);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<DeleteTarget | null>(null);
  // Right-click context menu: the row it targets (null = blank area).
  const [ctxMenu, setCtxMenu] = useState<{ x: number; y: number; row: TreeRow | null } | null>(
    null,
  );
  const ctxUploadDir = useRef<string | null>(null);
  const [uploading, setUploading] = useState(false);
  // Directory a drag is currently hovering over (drop target highlight).
  const [dropDir, setDropDir] = useState<string | null>(null);
  const uploadInputRef = useRef<HTMLInputElement>(null);
  const treeRef = useRef<HTMLDivElement>(null);

  const fetchDir = useCallback(
    async (target: string): Promise<Listing | null> => {
      const result = await listDirectory({
        input: { path: target },
        fields: DIR_FIELDS,
        headers: buildCSRFHeaders(),
      });
      if (result.success) return result.data as unknown as Listing;
      onError(result.errors[0]?.message ?? t("couldNotListDirectory"));
      return null;
    },
    [onError, t],
  );

  const refreshDir = useCallback(
    async (dir: string) => {
      const listing = await fetchDir(dir);
      if (listing) setChildren((prev) => ({ ...prev, [dir]: listing.entries }));
    },
    [fetchDir],
  );

  // (Re)load the tree root whenever the drawer path changes.
  useEffect(() => {
    let stale = false;
    void fetchDir(path).then((listing) => {
      if (stale || !listing) return;
      setRoot(listing);
      setChildren({ [listing.path]: listing.entries });
      setExpanded(new Set([listing.path]));
    });
    return () => {
      stale = true;
    };
  }, [path, fetchDir]);

  const toggleDir = async (dirPath: string) => {
    if (expanded.has(dirPath)) {
      setExpanded((prev) => {
        const next = new Set(prev);
        next.delete(dirPath);
        return next;
      });
      return;
    }

    if (!children[dirPath]) {
      setLoadingDirs((prev) => new Set(prev).add(dirPath));
      const listing = await fetchDir(dirPath);
      setLoadingDirs((prev) => {
        const next = new Set(prev);
        next.delete(dirPath);
        return next;
      });
      if (!listing) return;
      setChildren((prev) => ({ ...prev, [dirPath]: listing.entries }));
    }

    setExpanded((prev) => new Set(prev).add(dirPath));
  };

  const openFile = async (filePath: string, size: number, opts: { edit?: boolean } = {}) => {
    setPreviewLoading(filePath);
    const result = await loadPreview(filePath, size);
    setPreviewLoading(null);

    if (result.ok) {
      setEditOnOpen(Boolean(opts.edit));
      setPreview(result.preview);
    } else {
      onError(result.message ?? t("couldNotReadFile"));
    }
  };

  // Where an upload should land: the selected directory, a selected file's
  // directory, or the drawer root — VS Code explorer semantics.
  const uploadTargetDir = (): string | null => {
    const selected = selectable.find((row) => row.path === selectedPath);
    if (selected?.kind === "dir") return selected.path;
    if (selected?.kind === "file") return selected.parentDir;
    return root?.path ?? null;
  };

  const uploadTo = async (dir: string, files: File[]) => {
    if (files.length === 0) return;
    setUploading(true);

    for (const file of files) {
      const form = new FormData();
      form.append("dir", dir);
      form.append("file", file);

      try {
        const response = await fetch("/files/upload", {
          method: "POST",
          headers: buildCSRFHeaders(),
          body: form,
        });
        if (!response.ok) {
          let message = t("uploadFailed");
          try {
            message = (await response.json()).error ?? message;
          } catch {
            // Non-JSON error body: keep the generic message.
          }
          onError(message);
        }
      } catch {
        onError(t("uploadFailed"));
      }
    }

    setUploading(false);
    await refreshDir(dir);
    // Make the destination visible so the new files show up immediately.
    setExpanded((prev) => new Set(prev).add(dir));
  };

  const confirmDelete = async () => {
    const target = deleteTarget;
    if (!target) return;
    setDeleteTarget(null);

    const result = await deleteEntry({
      input: { path: target.path },
      fields: ["path"],
      headers: buildCSRFHeaders(),
    });
    if (!result.success) {
      onError(result.errors[0]?.message ?? t("somethingWentWrong"));
      return;
    }

    if (selectedPath === target.path) setSelectedPath(null);
    if (preview && preview.path.startsWith(target.path)) setPreview(null);
    await refreshDir(target.parentDir);
  };

  // The tree flattened to visible rows — one source of truth for both
  // rendering and keyboard navigation.
  const rows = useMemo<TreeRow[]>(() => {
    const out: TreeRow[] = [];
    if (root?.parent != null) out.push({ kind: "up", path: root.parent });

    const walk = (dirPath: string, depth: number) => {
      const all = children[dirPath];
      if (!all) return;

      const entries = all.filter((entry) => showHidden || !entry.name.startsWith("."));
      const hiddenCount = all.length - entries.length;

      for (const entry of entries) {
        const entryPath = join(dirPath, entry.name);
        if (entry.type === "directory") {
          out.push({ kind: "dir", path: entryPath, entry, depth, parentDir: dirPath });
          if (expanded.has(entryPath)) walk(entryPath, depth + 1);
        } else {
          out.push({ kind: "file", path: entryPath, entry, depth, parentDir: dirPath });
        }
      }

      if (hiddenCount > 0 && !showHidden) {
        out.push({
          kind: "note",
          id: dirPath + ":hidden",
          text: t("hiddenCount", { count: hiddenCount }),
          depth,
        });
      }
      if (all.length === 0) {
        out.push({ kind: "note", id: dirPath + ":empty", text: t("emptyDirectory"), depth });
      }
    };

    if (root) walk(root.path, 0);
    return out;
  }, [root, children, expanded, showHidden, t]);

  const selectable = useMemo(
    () => rows.filter((row): row is SelectableRow => row.kind !== "note"),
    [rows],
  );

  // Keep the keyboard selection visible while stepping through long listings.
  useEffect(() => {
    if (!selectedPath) return;
    const row = treeRef.current?.querySelector(`[data-path="${CSS.escape(selectedPath)}"]`);
    row?.scrollIntoView?.({ block: "nearest" });
  }, [selectedPath]);

  const activate = (row: SelectableRow) => {
    setSelectedPath(row.path);
    if (row.kind === "up") onNavigate(row.path);
    else if (row.kind === "dir") void toggleDir(row.path);
    else void openFile(row.path, row.entry.size);
  };

  const onTreeKeyDown = (e: React.KeyboardEvent) => {
    const index = selectable.findIndex((row) => row.path === selectedPath);
    const select = (i: number) => {
      const row = selectable[Math.max(0, Math.min(selectable.length - 1, i))];
      if (row) setSelectedPath(row.path);
    };
    const current = index >= 0 ? selectable[index] : undefined;

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        select(index + 1);
        break;

      case "ArrowUp":
        e.preventDefault();
        select(index < 0 ? 0 : index - 1);
        break;

      case "ArrowRight":
        if (current?.kind === "dir" && !expanded.has(current.path)) {
          e.preventDefault();
          void toggleDir(current.path);
        }
        break;

      case "ArrowLeft":
        if (current?.kind === "dir" && expanded.has(current.path)) {
          e.preventDefault();
          void toggleDir(current.path);
        }
        break;

      case "Enter":
        if (current) {
          e.preventDefault();
          activate(current);
        }
        break;

      case "Backspace":
        if (root?.parent != null) {
          e.preventDefault();
          onNavigate(root.parent);
        }
        break;

      case "Delete":
        if (current && current.kind !== "up") {
          e.preventDefault();
          setDeleteTarget({
            path: current.path,
            isDir: current.kind === "dir",
            parentDir: current.parentDir,
          });
        }
        break;

      // Deselect, so uploads/pastes target the root again.
      case "Escape":
        setSelectedPath(null);
        break;
    }
  };

  const segments = root ? crumbs(root.path) : [];

  return (
    <section
      id="file-drawer"
      className="fixed inset-0 z-30 flex h-full w-full shrink-0 flex-col border-l border-line bg-bg1 md:relative md:z-auto md:w-[var(--panel-w,22rem)]"
      style={width ? ({ "--panel-w": `${width}px` } as React.CSSProperties) : undefined}
    >
      {onResize && <ResizeHandle id="drawer-resize" edge="left" onResize={onResize} onReset={onResetWidth} />}
      <header className="flex items-center gap-2 border-b border-line px-3 py-2.5">
        <span className="text-xs font-medium uppercase tracking-wider text-fg-muted">
          {t("filesTitle")}
        </span>
        <div className="flex-1" />
        <button
          id="upload-button"
          onClick={() => uploadInputRef.current?.click()}
          disabled={uploading || !root}
          className="grid h-6 w-6 place-items-center rounded border border-line text-fg-muted transition-colors hover:border-mint/50 hover:text-mint disabled:opacity-50"
          title={`${t("upload")} → ${uploadTargetDir() ?? ""}`}
        >
          {uploading ? (
            <span className="font-mono text-[11px] text-mint">…</span>
          ) : (
            <UploadIcon />
          )}
        </button>
        <input
          ref={uploadInputRef}
          type="file"
          multiple
          className="hidden"
          onChange={(e) => {
            const files = Array.from(e.target.files ?? []);
            e.target.value = "";
            const dir = ctxUploadDir.current ?? uploadTargetDir();
            ctxUploadDir.current = null;
            if (dir) void uploadTo(dir, files);
          }}
        />
        <button
          onClick={onToggleFollow}
          className={`rounded-md border px-1.5 py-0.5 font-mono text-[11px] transition-colors ${
            followCwd ? "border-mint/50 text-mint" : "border-line text-fg-muted hover:text-fg"
          }`}
          title={t("followCwd")}
        >
          {t("followCwd")}
        </button>
        <button
          onClick={() => setShowHidden((v) => !v)}
          className={`rounded-md border px-1.5 py-0.5 font-mono text-[11px] transition-colors ${
            showHidden ? "border-mint/50 text-mint" : "border-line text-fg-muted hover:text-fg"
          }`}
          title={t("showHidden")}
        >
          {t("showHidden")}
        </button>
        <button
          onClick={onClose}
          className="ml-1 grid h-6 w-6 place-items-center rounded text-fg-muted transition-colors hover:text-fg"
          title={t("closeFileDrawer")}
        >
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M4 4l8 8M12 4l-8 8" strokeLinecap="round" />
          </svg>
        </button>
      </header>

      <div className="flex flex-wrap items-center gap-x-0.5 border-b border-line px-3 py-1.5 font-mono text-xs text-fg-muted">
        {segments.map((seg, i) => (
          <React.Fragment key={seg.path}>
            {i > 0 && <span className="text-fg-muted/50">/</span>}
            <button
              onClick={() => onNavigate(seg.path)}
              className="rounded px-0.5 transition-colors hover:text-fg"
            >
              {seg.label}
            </button>
          </React.Fragment>
        ))}
      </div>

      <div
        id="file-tree"
        ref={treeRef}
        tabIndex={0}
        role="tree"
        onKeyDown={onTreeKeyDown}
        onClick={(e) => {
          // Clicking the empty area below the rows deselects (uploads and
          // pastes then target the drawer root again).
          if (e.target === e.currentTarget) setSelectedPath(null);
        }}
        onPaste={(e) => {
          // Files copied in the OS file manager and pasted here (Ctrl+V).
          const files = collectTransferFiles(e.clipboardData);
          if (files.length === 0) return;
          e.preventDefault();
          const dir = uploadTargetDir();
          if (dir) void uploadTo(dir, files);
        }}
        onDragOver={(e) => {
          e.preventDefault();
          const row = (e.target as HTMLElement).closest("[data-dropdir]");
          setDropDir(row?.getAttribute("data-dropdir") ?? root?.path ?? null);
        }}
        onDragLeave={(e) => {
          if (e.target === e.currentTarget) setDropDir(null);
        }}
        onDrop={(e) => {
          const files = collectTransferFiles(e.dataTransfer);
          const row = (e.target as HTMLElement).closest("[data-dropdir]");
          const dir = row?.getAttribute("data-dropdir") ?? root?.path ?? null;
          setDropDir(null);
          if (files.length === 0 || !dir) return;
          e.preventDefault();
          void uploadTo(dir, files);
        }}
        onContextMenu={(e) => {
          e.preventDefault();
          const target = (e.target as HTMLElement).closest("[data-path]");
          const row = target
            ? (rows.find(
                (r) => (r.kind === "dir" || r.kind === "file") && r.path === target.getAttribute("data-path"),
              ) as TreeRow | undefined)
            : undefined;
          setCtxMenu({ x: e.clientX, y: e.clientY, row: row ?? null });
        }}
        className="flex-1 overflow-y-auto py-1 outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-mint/40"
      >
        {rows.map((row) => {
          if (row.kind === "note") {
            return (
              <div
                key={row.id}
                className="px-3 py-1 font-mono text-[11px] text-fg-muted/60"
                style={{ paddingLeft: 12 + row.depth * 14 }}
              >
                {row.text}
              </div>
            );
          }

          if (row.kind === "up") {
            return (
              <Row
                key={".."}
                path={row.path}
                dropDir={root?.path ?? null}
                depth={0}
                icon={<span className="w-3.5" />}
                extraIcon={<FileTypeIcon name=".." isDir />}
                name=".."
                selected={selectedPath === row.path}
                onClick={() => activate(row)}
              />
            );
          }

          const isDir = row.kind === "dir";
          return (
            <Row
              key={row.path}
              path={row.path}
              dropDir={isDir ? row.path : row.parentDir}
              dropTarget={dropDir != null && dropDir === (isDir ? row.path : row.parentDir)}
              depth={row.depth}
              icon={
                isDir ? (
                  <Chevron open={expanded.has(row.path)} loading={loadingDirs.has(row.path)} />
                ) : (
                  <span className="w-3.5" />
                )
              }
              extraIcon={
                <FileTypeIcon name={row.entry.name} isDir={isDir} isOpen={expanded.has(row.path)} />
              }
              name={row.entry.name}
              symlink={row.entry.symlink}
              detail={isDir ? undefined : humanBytes(row.entry.size)}
              loading={previewLoading === row.path}
              selected={selectedPath === row.path}
              onClick={() => activate(row)}
              actions={
                <>
                  {!isDir && /\.(html?|xhtml|svg|pdf)$/i.test(row.path) && (
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        window.open(rawFileUrl(row.path), "_blank");
                      }}
                      className="grid h-5 w-5 place-items-center rounded text-fg-muted hover:text-mint"
                      title={t("openInBrowser")}
                      data-open-browser={row.path}
                    >
                      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
                        <path d="M6.5 3H3v10h10V9.5M9.5 3H13v3.5M13 3 7.5 8.5" strokeLinecap="round" strokeLinejoin="round" />
                      </svg>
                    </button>
                  )}
                  {!isDir && (
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        void openFile(row.path, row.entry.size, { edit: true });
                      }}
                      className="grid h-5 w-5 place-items-center rounded text-fg-muted hover:text-mint"
                      title={t("edit")}
                      data-edit={row.path}
                    >
                      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
                        <path
                          d="M11.1 2.9a1.75 1.75 0 0 1 2.47 2.47L6.2 12.75l-3.45.85.85-3.45z"
                          strokeLinejoin="round"
                        />
                      </svg>
                    </button>
                  )}
                  {!isDir && (
                    <a
                      href={rawFileUrl(row.path, true)}
                      onClick={(e) => e.stopPropagation()}
                      className="grid h-5 w-5 place-items-center rounded text-fg-muted hover:text-mint"
                      title={t("download")}
                      data-download={row.path}
                    >
                      <DownloadIcon />
                    </a>
                  )}
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      setDeleteTarget({ path: row.path, isDir, parentDir: row.parentDir });
                    }}
                    className="grid h-5 w-5 place-items-center rounded text-fg-muted hover:text-danger"
                    title={t("deleteEntry")}
                    data-delete={row.path}
                  >
                    <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
                      <path d="m4 4 8 8m0-8-8 8" strokeLinecap="round" />
                    </svg>
                  </button>
                </>
              }
            />
          );
        })}
      </div>

      <footer className="hidden shrink-0 flex-wrap items-center gap-x-3 gap-y-0.5 border-t border-line px-3 py-1.5 font-mono text-[10px] leading-4 text-fg-muted/70 md:flex">
        <KeyHint keys="↑↓" label={t("hintSelect")} />
        <KeyHint keys="⏎" label={t("hintOpen")} />
        <KeyHint keys="⌫" label={t("hintParent")} />
        <KeyHint keys="Del" label={t("deleteEntry")} />
        <KeyHint keys="Esc" label={t("hintDeselect")} />
        <KeyHint keys={`${modLabel}+V`} label={t("hintPaste")} />
      </footer>

      {ctxMenu && (
        <>
          <div
            className="fixed inset-0 z-40"
            onClick={() => setCtxMenu(null)}
            onContextMenu={(e) => {
              e.preventDefault();
              setCtxMenu(null);
            }}
          />
          <div
            id="drawer-context-menu"
            className="fixed z-50 min-w-44 rounded-md border border-line bg-bg1 py-1 shadow-xl shadow-black/50"
            style={{
              left: Math.min(ctxMenu.x, window.innerWidth - 190),
              top: Math.min(ctxMenu.y, window.innerHeight - 180),
            }}
          >
            {(() => {
              const row = ctxMenu.row;
              const close = () => setCtxMenu(null);
              const item = (
                key: string,
                label: string,
                onPick: () => void,
                danger = false,
              ) => (
                <button
                  key={key}
                  data-ctx-item={key}
                  onClick={() => {
                    close();
                    onPick();
                  }}
                  className={`block w-full px-3 py-1.5 text-left font-mono text-xs transition-colors ${
                    danger
                      ? "text-fg-muted hover:bg-[#e5716e]/10 hover:text-[#e5716e]"
                      : "text-fg-muted hover:bg-bg2 hover:text-fg"
                  }`}
                >
                  {label}
                </button>
              );

              if (row && row.kind === "file") {
                const html = /\.(html?|xhtml)$/i.test(row.path);
                return [
                  item("open", t("hintOpen"), () => void openFile(row.path, row.entry.size)),
                  ...(html
                    ? [
                        item("open-browser", t("openInBrowser"), () =>
                          window.open(rawFileUrl(row.path), "_blank"),
                        ),
                      ]
                    : []),
                  item("download", t("download"), () => {
                    const a = document.createElement("a");
                    a.href = rawFileUrl(row.path, true);
                    a.click();
                  }),
                  item("copy-path", t("copyPath"), () => void writeClipboard(row.path)),
                  item("copy-relative-path", t("copyRelativePath"), () =>
                    void writeClipboard(relativePath(root?.path ?? "/", row.path)),
                  ),
                  item(
                    "delete",
                    t("deleteEntry"),
                    () => setDeleteTarget({ path: row.path, isDir: false, parentDir: row.parentDir }),
                    true,
                  ),
                ];
              }
              if (row && row.kind === "dir") {
                return [
                  item("upload-here", t("uploadHere"), () => {
                    ctxUploadDir.current = row.path;
                    uploadInputRef.current?.click();
                  }),
                  item("copy-path", t("copyPath"), () => void writeClipboard(row.path)),
                  item("copy-relative-path", t("copyRelativePath"), () =>
                    void writeClipboard(relativePath(root?.path ?? "/", row.path)),
                  ),
                  item(
                    "delete",
                    t("deleteEntry"),
                    () => setDeleteTarget({ path: row.path, isDir: true, parentDir: row.parentDir }),
                    true,
                  ),
                ];
              }
              return [
                item("upload", t("upload"), () => {
                  ctxUploadDir.current = root?.path ?? null;
                  uploadInputRef.current?.click();
                }),
                item("copy-path", t("copyPath"), () => void writeClipboard(root?.path ?? "")),
              ];
            })()}
          </div>
        </>
      )}

      {deleteTarget && (
        <div
          className="fixed inset-0 z-40 grid place-items-center bg-black/60 p-4 sm:p-6"
          onClick={() => setDeleteTarget(null)}
        >
          <div
            id="delete-entry-modal"
            className="w-full max-w-sm rounded-xl border border-line bg-bg1 shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <header className="border-b border-line px-4 py-3">
              <span className="text-[15px] font-medium text-fg">{t("reallyDelete")}</span>
            </header>
            <div className="flex items-center gap-2 px-4 py-4">
              <FileTypeIcon name={deleteTarget.path} isDir={deleteTarget.isDir} />
              <span className="truncate font-mono text-sm text-fg" title={deleteTarget.path}>
                {deleteTarget.path}
              </span>
            </div>
            <footer className="flex justify-end gap-2 border-t border-line px-4 py-3">
              <button
                id="cancel-delete-entry-button"
                onClick={() => setDeleteTarget(null)}
                className="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-[13px] text-fg-muted transition-colors hover:text-fg"
              >
                {t("cancel")} <Kbd>Esc</Kbd>
              </button>
              <button
                id="confirm-delete-entry-button"
                autoFocus
                onKeyDown={(e) => {
                  if (e.key === "Escape") setDeleteTarget(null);
                }}
                onClick={() => void confirmDelete()}
                className="inline-flex items-center gap-1.5 rounded-md bg-danger/90 px-3 py-1.5 text-[13px] font-medium text-black transition-colors hover:bg-danger"
              >
                {t("deleteEntry")} <Kbd>⏎</Kbd>
              </button>
            </footer>
          </div>
        </div>
      )}

      {preview && (
        <FilePreview
          preview={preview}
          startInEdit={editOnOpen}
          onClose={() => setPreview(null)}
          onError={onError}
          onSaved={(savedPath, savedContent, savedSize) => {
            setPreview((current) =>
              current && "content" in current && current.path === savedPath
                ? { ...current, content: savedContent, size: savedSize }
                : current,
            );
            // Refresh the file's directory (if loaded) so the tree shows the
            // new size.
            const dir = savedPath.slice(0, savedPath.lastIndexOf("/")) || "/";
            void refreshDir(dir);
          }}
        />
      )}
    </section>
  );
}

function crumbs(path: string): { label: string; path: string }[] {
  if (path === "/") return [{ label: "/", path: "/" }];
  const parts = path.split("/").filter(Boolean);
  const out = [{ label: "/", path: "/" }];
  let acc = "";
  for (const part of parts) {
    acc += "/" + part;
    out.push({ label: part, path: acc });
  }
  return out;
}

function Row({
  path,
  dropDir,
  dropTarget,
  depth,
  icon,
  extraIcon,
  name,
  detail,
  symlink,
  loading,
  selected,
  onClick,
  actions,
}: {
  path: string;
  dropDir?: string | null;
  dropTarget?: boolean;
  depth: number;
  icon: React.ReactNode;
  extraIcon: React.ReactNode;
  name: string;
  detail?: string;
  symlink?: boolean;
  loading?: boolean;
  selected?: boolean;
  onClick: () => void;
  actions?: React.ReactNode;
}) {
  return (
    <div
      role="treeitem"
      aria-selected={selected}
      data-path={path}
      data-dropdir={dropDir ?? undefined}
      onClick={onClick}
      className={`group flex w-full cursor-pointer items-center gap-1.5 px-3 py-[5px] text-left transition-colors ${
        selected ? "bg-bg2 " : "hover:bg-bg2/70"
      } ${dropTarget ? "bg-mint/10" : ""}`}
      style={{ paddingLeft: 12 + depth * 14 }}
    >
      <span className="grid w-3.5 shrink-0 place-items-center text-fg-muted">{icon}</span>
      <span className="shrink-0 text-fg-muted">{extraIcon}</span>
      <span className="min-w-0 flex-1 truncate font-mono text-[13px] text-fg">
        {name}
        {symlink && <span className="text-fg-muted"> ⇢</span>}
      </span>
      {actions && (
        <span className="hidden shrink-0 items-center gap-0.5 group-hover:flex">{actions}</span>
      )}
      {loading ? (
        <span className="shrink-0 font-mono text-[11px] text-mint">…</span>
      ) : (
        detail && (
          <span className="shrink-0 font-mono text-[11px] text-fg-muted group-hover:hidden">
            {detail}
          </span>
        )
      )}
    </div>
  );
}

function Chevron({ open, loading }: { open: boolean; loading: boolean }) {
  if (loading) return <span className="font-mono text-[11px] text-mint">…</span>;
  return (
    <svg
      viewBox="0 0 16 16"
      className={`h-3 w-3 transition-transform ${open ? "rotate-90" : ""}`}
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
    >
      <path d="M6 4l4 4-4 4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function UploadIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M8 10.5v-7M4.5 6.5 8 3l3.5 3.5M3 12.5h10" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M8 3v7M4.5 6.5 8 10l3.5-3.5M3 12.5h10" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
