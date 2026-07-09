import React, { useCallback, useEffect, useState } from "react";
import { buildCSRFHeaders, listDirectory, readFile } from "../ash_rpc";
import type { ListDirectoryFields, ReadFileFields } from "../ash_rpc";
import { humanBytes } from "./util";
import { useI18n } from "./i18n";
import FilePreview, { type Preview } from "./FilePreview";
import { previewKind } from "./fileTypes";
import { FileTypeIcon } from "./fileIcons";

// "entries" as a leaf field returns the full entry maps; the generated
// selection type has no shape for arrays of typed maps, hence the cast.
const DIR_FIELDS = ["path", "parent", "entries"] as unknown as ListDirectoryFields;

const FILE_FIELDS: ReadFileFields = ["path", "size", "truncated", "binary", "content"];

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

type Props = {
  path: string;
  followCwd: boolean;
  onNavigate: (path: string) => void;
  onToggleFollow: () => void;
  onClose: () => void;
  onError: (message: string) => void;
};

function join(dir: string, name: string): string {
  return `${dir === "/" ? "" : dir}/${name}`;
}

export default function FileDrawer({
  path,
  followCwd,
  onNavigate,
  onToggleFollow,
  onClose,
  onError,
}: Props) {
  const { t } = useI18n();
  const [root, setRoot] = useState<Listing | null>(null);
  const [children, setChildren] = useState<Record<string, Entry[]>>({});
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [loadingDirs, setLoadingDirs] = useState<Set<string>>(new Set());
  const [showHidden, setShowHidden] = useState(false);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [previewLoading, setPreviewLoading] = useState<string | null>(null);

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

  const openFile = async (filePath: string, size: number) => {
    const kind = previewKind(filePath);

    if (kind === "image") {
      setPreview({ kind: "image", path: filePath, size });
      return;
    }

    setPreviewLoading(filePath);
    const result = await readFile({
      input: { path: filePath },
      fields: FILE_FIELDS,
      headers: buildCSRFHeaders(),
    });
    setPreviewLoading(null);

    if (!result.success) {
      onError(result.errors[0]?.message ?? t("couldNotReadFile"));
      return;
    }

    const data = result.data as unknown as {
      path: string;
      size: number;
      truncated: boolean;
      binary: boolean;
      content: string | null;
    };

    if (data.binary) {
      setPreview({ kind: "binary", path: data.path, size: data.size });
    } else {
      setPreview({
        kind,
        path: data.path,
        size: data.size,
        truncated: data.truncated,
        content: data.content ?? "",
      });
    }
  };

  const renderEntries = (dirPath: string, depth: number): React.ReactNode => {
    const entries = (children[dirPath] ?? []).filter(
      (entry) => showHidden || !entry.name.startsWith("."),
    );
    const hiddenCount = (children[dirPath]?.length ?? 0) - entries.length;

    return (
      <>
        {entries.map((entry) => {
          const entryPath = join(dirPath, entry.name);

          if (entry.type === "directory") {
            const isOpen = expanded.has(entryPath);
            return (
              <React.Fragment key={entryPath}>
                <Row
                  depth={depth}
                  icon={<Chevron open={isOpen} loading={loadingDirs.has(entryPath)} />}
                  extraIcon={<FileTypeIcon name={entry.name} isDir isOpen={isOpen} />}
                  name={entry.name}
                  symlink={entry.symlink}
                  onClick={() => void toggleDir(entryPath)}
                />
                {isOpen && renderEntries(entryPath, depth + 1)}
              </React.Fragment>
            );
          }

          return (
            <Row
              key={entryPath}
              depth={depth}
              icon={<span className="w-3.5" />}
              extraIcon={<FileTypeIcon name={entry.name} />}
              name={entry.name}
              symlink={entry.symlink}
              detail={humanBytes(entry.size)}
              loading={previewLoading === entryPath}
              onClick={() => void openFile(entryPath, entry.size)}
            />
          );
        })}
        {hiddenCount > 0 && !showHidden && (
          <div
            className="px-3 py-1 font-mono text-[11px] text-fg-muted/60"
            style={{ paddingLeft: 12 + depth * 14 }}
          >
            {t("hiddenCount", { count: hiddenCount })}
          </div>
        )}
        {children[dirPath] && children[dirPath].length === 0 && (
          <div
            className="px-3 py-1 font-mono text-[11px] text-fg-muted/60"
            style={{ paddingLeft: 12 + depth * 14 }}
          >
            {t("emptyDirectory")}
          </div>
        )}
      </>
    );
  };

  const segments = root ? crumbs(root.path) : [];

  return (
    <section
      id="file-drawer"
      className="fixed inset-0 z-30 flex h-full w-full shrink-0 flex-col border-l border-line bg-bg1 md:static md:z-auto md:w-[22rem]"
    >
      <header className="flex items-center gap-2 border-b border-line px-3 py-2.5">
        <span className="text-xs font-medium uppercase tracking-wider text-fg-muted">
          {t("filesTitle")}
        </span>
        <div className="flex-1" />
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

      <div id="file-tree" className="flex-1 overflow-y-auto py-1">
        {root?.parent != null && (
          <Row
            depth={0}
            icon={<span className="w-3.5" />}
            extraIcon={<FileTypeIcon name=".." isDir />}
            name=".."
            onClick={() => onNavigate(root.parent!)}
          />
        )}
        {root && renderEntries(root.path, 0)}
      </div>

      {preview && (
        <FilePreview
          preview={preview}
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
            void fetchDir(dir).then((listing) => {
              if (listing) {
                setChildren((prev) =>
                  prev[dir] ? { ...prev, [dir]: listing.entries } : prev,
                );
              }
            });
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
  depth,
  icon,
  extraIcon,
  name,
  detail,
  symlink,
  loading,
  onClick,
}: {
  depth: number;
  icon: React.ReactNode;
  extraIcon: React.ReactNode;
  name: string;
  detail?: string;
  symlink?: boolean;
  loading?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex w-full items-center gap-1.5 px-3 py-[5px] text-left transition-colors hover:bg-bg2/70"
      style={{ paddingLeft: 12 + depth * 14 }}
    >
      <span className="grid w-3.5 shrink-0 place-items-center text-fg-muted">{icon}</span>
      <span className="shrink-0 text-fg-muted">{extraIcon}</span>
      <span className="min-w-0 flex-1 truncate font-mono text-[13px] text-fg">
        {name}
        {symlink && <span className="text-fg-muted"> ⇢</span>}
      </span>
      {loading ? (
        <span className="shrink-0 font-mono text-[11px] text-mint">…</span>
      ) : (
        detail && <span className="shrink-0 font-mono text-[11px] text-fg-muted">{detail}</span>
      )}
    </button>
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


