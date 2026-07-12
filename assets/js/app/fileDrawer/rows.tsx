import React from "react";

export function Row({
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

export function Chevron({ open, loading }: { open: boolean; loading: boolean }) {
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

export function UploadIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M8 10.5v-7M4.5 6.5 8 3l3.5 3.5M3 12.5h10" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function DownloadIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M8 3v7M4.5 6.5 8 10l3.5-3.5M3 12.5h10" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
