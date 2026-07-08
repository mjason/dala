import React, { useCallback, useEffect, useState } from "react";
import { buildCSRFHeaders, listDirectory, readFile } from "../ash_rpc";
import type { ListDirectoryFields, ReadFileFields } from "../ash_rpc";
import { humanBytes, timeAgo } from "./util";

// "entries" as a leaf field returns the full entry maps; the generated
// selection type has no shape for arrays of typed maps, hence the cast.
const DIR_FIELDS = ["path", "parent", "entries"] as unknown as ListDirectoryFields;

const FILE_FIELDS: ReadFileFields = ["path", "size", "truncated", "binary", "content"];

type Entry = {
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

type Preview = {
  path: string;
  size: number;
  truncated: boolean;
  binary: boolean;
  content: string | null;
};

type Props = {
  path: string;
  followCwd: boolean;
  onNavigate: (path: string) => void;
  onToggleFollow: () => void;
  onClose: () => void;
  onError: (message: string) => void;
};

export default function FileDrawer({
  path,
  followCwd,
  onNavigate,
  onToggleFollow,
  onClose,
  onError,
}: Props) {
  const [listing, setListing] = useState<Listing | null>(null);
  const [loading, setLoading] = useState(false);
  const [showHidden, setShowHidden] = useState(false);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [previewLoading, setPreviewLoading] = useState<string | null>(null);

  const load = useCallback(
    async (target: string) => {
      setLoading(true);
      const result = await listDirectory({
        input: { path: target },
        fields: DIR_FIELDS,
        headers: buildCSRFHeaders(),
      });
      setLoading(false);
      if (result.success) {
        setListing(result.data as unknown as Listing);
      } else {
        onError(result.errors[0]?.message ?? "Could not list directory");
      }
    },
    [onError],
  );

  useEffect(() => {
    void load(path);
  }, [path, load]);

  const openFile = async (name: string) => {
    if (!listing) return;
    const filePath = `${listing.path === "/" ? "" : listing.path}/${name}`;
    setPreviewLoading(name);
    const result = await readFile({
      input: { path: filePath },
      fields: FILE_FIELDS,
      headers: buildCSRFHeaders(),
    });
    setPreviewLoading(null);
    if (result.success) {
      setPreview(result.data as unknown as Preview);
    } else {
      onError(result.errors[0]?.message ?? "Could not read file");
    }
  };

  const entries = (listing?.entries ?? []).filter(
    (e) => showHidden || !e.name.startsWith("."),
  );
  const hiddenCount = (listing?.entries.length ?? 0) - entries.length;
  const segments = listing ? crumbs(listing.path) : [];

  return (
    <section
      id="file-drawer"
      className="flex h-full w-80 shrink-0 flex-col border-l border-line bg-bg1"
    >
      <header className="flex items-center gap-2 border-b border-line px-3 py-2.5">
        <span className="text-[11px] font-medium uppercase tracking-wider text-fg-muted">
          Files
        </span>
        <div className="flex-1" />
        <button
          onClick={onToggleFollow}
          className={`rounded-md border px-1.5 py-0.5 font-mono text-[10px] transition-colors ${
            followCwd
              ? "border-mint/50 text-mint"
              : "border-line text-fg-muted hover:text-fg"
          }`}
          title="Follow the terminal's working directory"
        >
          follow cwd
        </button>
        <button
          onClick={() => setShowHidden((v) => !v)}
          className={`rounded-md border px-1.5 py-0.5 font-mono text-[10px] transition-colors ${
            showHidden ? "border-mint/50 text-mint" : "border-line text-fg-muted hover:text-fg"
          }`}
          title="Show dotfiles"
        >
          .hidden
        </button>
        <button
          onClick={onClose}
          className="ml-1 grid h-5 w-5 place-items-center rounded text-fg-muted transition-colors hover:text-fg"
          title="Close file drawer"
        >
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M4 4l8 8M12 4l-8 8" strokeLinecap="round" />
          </svg>
        </button>
      </header>

      <div className="flex flex-wrap items-center gap-x-0.5 border-b border-line px-3 py-1.5 font-mono text-[11px] text-fg-muted">
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

      <div className="relative flex-1 overflow-y-auto py-1">
        {loading && (
          <div className="absolute inset-x-0 top-0 h-0.5 animate-pulse bg-mint/60" />
        )}
        {listing?.parent != null && (
          <Row
            icon={<DirIcon />}
            name=".."
            onClick={() => onNavigate(listing.parent!)}
          />
        )}
        {entries.map((entry) =>
          entry.type === "directory" ? (
            <Row
              key={entry.name}
              icon={<DirIcon />}
              name={entry.name}
              symlink={entry.symlink}
              onClick={() =>
                onNavigate(`${listing!.path === "/" ? "" : listing!.path}/${entry.name}`)
              }
            />
          ) : (
            <Row
              key={entry.name}
              icon={<FileIcon />}
              name={entry.name}
              symlink={entry.symlink}
              detail={`${humanBytes(entry.size)}${entry.mtime ? " · " + timeAgo(entry.mtime) : ""}`}
              loading={previewLoading === entry.name}
              onClick={() => void openFile(entry.name)}
            />
          ),
        )}
        {hiddenCount > 0 && !showHidden && (
          <div className="px-3 py-1.5 font-mono text-[10px] text-fg-muted/60">
            {hiddenCount} hidden
          </div>
        )}
        {listing && listing.entries.length === 0 && (
          <div className="px-3 py-6 text-center text-xs text-fg-muted">Empty directory</div>
        )}
      </div>

      {preview && (
        <div
          className="fixed inset-0 z-40 grid place-items-center bg-black/60 p-8"
          onClick={() => setPreview(null)}
        >
          <div
            id="file-preview"
            className="flex max-h-full w-full max-w-3xl flex-col overflow-hidden rounded-xl border border-line bg-bg1 shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <header className="flex items-center gap-3 border-b border-line px-4 py-2.5">
              <span className="truncate font-mono text-xs text-fg">{preview.path}</span>
              <span className="shrink-0 font-mono text-[10px] text-fg-muted">
                {humanBytes(preview.size)}
                {preview.truncated && " · preview truncated"}
              </span>
              <div className="flex-1" />
              <button
                onClick={() => setPreview(null)}
                className="grid h-6 w-6 place-items-center rounded text-fg-muted hover:text-fg"
              >
                <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
                  <path d="M4 4l8 8M12 4l-8 8" strokeLinecap="round" />
                </svg>
              </button>
            </header>
            {preview.binary ? (
              <div className="px-4 py-10 text-center text-xs text-fg-muted">
                Binary file — no preview.
              </div>
            ) : (
              <pre className="overflow-auto px-4 py-3 font-mono text-xs leading-5 text-fg">
                {preview.content}
              </pre>
            )}
          </div>
        </div>
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
  icon,
  name,
  detail,
  symlink,
  loading,
  onClick,
}: {
  icon: React.ReactNode;
  name: string;
  detail?: string;
  symlink?: boolean;
  loading?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex w-full items-center gap-2 px-3 py-[5px] text-left transition-colors hover:bg-bg2/70"
    >
      <span className="shrink-0 text-fg-muted">{icon}</span>
      <span className="min-w-0 flex-1 truncate font-mono text-xs text-fg">
        {name}
        {symlink && <span className="text-fg-muted"> ⇢</span>}
      </span>
      {loading ? (
        <span className="shrink-0 font-mono text-[10px] text-mint">…</span>
      ) : (
        detail && <span className="shrink-0 font-mono text-[10px] text-fg-muted">{detail}</span>
      )}
    </button>
  );
}

function DirIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="currentColor" opacity="0.75">
      <path d="M1.5 3.5A1.5 1.5 0 0 1 3 2h3l1.5 1.5H13A1.5 1.5 0 0 1 14.5 5v7A1.5 1.5 0 0 1 13 13.5H3A1.5 1.5 0 0 1 1.5 12z" />
    </svg>
  );
}

function FileIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.2" opacity="0.75">
      <path d="M4 1.5h5L12.5 5v9A.5.5 0 0 1 12 14.5H4a.5.5 0 0 1-.5-.5V2a.5.5 0 0 1 .5-.5z" />
      <path d="M9 1.5V5h3.5" />
    </svg>
  );
}
