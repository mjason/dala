import React, { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { GitDecoration } from "../gitDecorations";

const DECORATION_CLASSES: Record<GitDecoration["tone"], string> = {
  added: "text-git-added",
  modified: "text-git-modified",
  deleted: "text-git-deleted",
  renamed: "text-git-renamed",
  untracked: "text-git-untracked",
  conflict: "text-git-conflict",
  ignored: "text-git-ignored",
};

const TOOLTIP_DELAY_MS = 350;
const TOOLTIP_GAP_PX = 8;
const TOOLTIP_MARGIN_PX = 8;

type Rect = Pick<DOMRect, "top" | "right" | "bottom" | "left">;
type Size = { width: number; height: number };
type Viewport = { width: number; height: number };

export type TooltipPosition = {
  left: number;
  top: number;
  placement: "left" | "right" | "above" | "below";
};

function initial(directory: string): string {
  const chars = Array.from(directory);
  if (chars[0] === "." && chars[1]) return `.${chars[1]}`;
  return chars[0] ?? directory;
}

/** Keep the leaf name intact while reducing long directory paths to useful landmarks. */
export function compactPath(path: string, maxLength = 72): string {
  if (Array.from(path).length <= maxLength) return path;

  const separator = path.includes("\\") && !path.includes("/") ? "\\" : "/";
  const hasLeadingSeparator = path.startsWith(separator);
  const parts = path.split(separator).filter(Boolean);
  if (parts.length < 2) return path;

  const leaf = parts.at(-1)!;
  const directories = parts.slice(0, -1);
  const shortened = directories.map((directory, index) => {
    const isLandmark = index === 0 || index === directories.length - 1;
    return isLandmark || Array.from(directory).length <= 4 ? directory : initial(directory);
  });
  const prefix = hasLeadingSeparator ? separator : "";
  const join = (items: string[]) => `${prefix}${[...items, leaf].join(separator)}`;

  let compact = join(shortened);
  if (Array.from(compact).length <= maxLength) return compact;

  if (shortened.length > 2) compact = join([shortened[0], "...", shortened.at(-1)!]);
  return compact;
}

/** Position beside the row when possible, then fall back above or below it. */
export function placeTooltip(anchor: Rect, tooltip: Size, viewport: Viewport): TooltipPosition {
  const fitsRight = anchor.right + TOOLTIP_GAP_PX + tooltip.width <= viewport.width - TOOLTIP_MARGIN_PX;
  const fitsLeft = anchor.left - TOOLTIP_GAP_PX - tooltip.width >= TOOLTIP_MARGIN_PX;

  let placement: TooltipPosition["placement"];
  let left: number;
  let top: number;

  if (fitsRight) {
    placement = "right";
    left = anchor.right + TOOLTIP_GAP_PX;
    top = anchor.top;
  } else if (fitsLeft) {
    placement = "left";
    left = anchor.left - TOOLTIP_GAP_PX - tooltip.width;
    top = anchor.top;
  } else {
    const fitsBelow = anchor.bottom + TOOLTIP_GAP_PX + tooltip.height <= viewport.height - TOOLTIP_MARGIN_PX;
    placement = fitsBelow ? "below" : "above";
    left = anchor.left;
    top = fitsBelow
      ? anchor.bottom + TOOLTIP_GAP_PX
      : anchor.top - TOOLTIP_GAP_PX - tooltip.height;
  }

  return {
    placement,
    left: Math.max(
      TOOLTIP_MARGIN_PX,
      Math.min(left, viewport.width - tooltip.width - TOOLTIP_MARGIN_PX),
    ),
    top: Math.max(
      TOOLTIP_MARGIN_PX,
      Math.min(top, viewport.height - tooltip.height - TOOLTIP_MARGIN_PX),
    ),
  };
}

export function PathTooltip({
  anchor,
  id,
  name,
  path,
  onDismiss,
}: {
  anchor: React.RefObject<HTMLElement | null>;
  id: string;
  name: string;
  path: string;
  onDismiss: () => void;
}) {
  const tooltipRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<TooltipPosition | null>(null);

  const updatePosition = useCallback(() => {
    const anchorElement = anchor.current;
    const tooltipElement = tooltipRef.current;
    if (!anchorElement || !tooltipElement) return;

    setPosition(
      placeTooltip(anchorElement.getBoundingClientRect(), tooltipElement.getBoundingClientRect(), {
        width: window.innerWidth,
        height: window.innerHeight,
      }),
    );
  }, [anchor]);

  useLayoutEffect(updatePosition, [updatePosition]);

  useEffect(() => {
    const dismissOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onDismiss();
    };
    // The row's own mouseleave is NOT enough to close: when an overlay
    // (file preview) opens over a stationary pointer, no leave event ever
    // fires and the tip would sit on top of the overlay forever. Watching
    // where the pointer actually IS closes it the moment it hovers
    // anything outside the anchor row.
    const dismissOffAnchor = (event: PointerEvent) => {
      const anchorElement = anchor.current;
      if (!anchorElement?.contains(event.target as Node)) onDismiss();
    };
    window.addEventListener("scroll", onDismiss, true);
    window.addEventListener("resize", onDismiss);
    window.addEventListener("keydown", dismissOnEscape);
    window.addEventListener("pointerover", dismissOffAnchor, true);
    return () => {
      window.removeEventListener("scroll", onDismiss, true);
      window.removeEventListener("resize", onDismiss);
      window.removeEventListener("keydown", dismissOnEscape);
      window.removeEventListener("pointerover", dismissOffAnchor, true);
    };
  }, [onDismiss, anchor]);

  return createPortal(
    <div
      ref={tooltipRef}
      id={id}
      role="tooltip"
      data-file-path-tooltip
      data-placement={position?.placement}
      className="pointer-events-none fixed z-[100] w-max rounded-md border border-line bg-bg1 px-3 py-2 shadow-xl shadow-black/40"
      style={{
        left: position?.left ?? TOOLTIP_MARGIN_PX,
        top: position?.top ?? TOOLTIP_MARGIN_PX,
        maxWidth: "min(26rem, calc(100vw - 1rem))",
        visibility: position ? "visible" : "hidden",
      }}
    >
      <div
        data-tooltip-name
        className="break-all font-mono text-[12px] font-medium leading-[18px] text-fg"
      >
        {name}
      </div>
      <div
        data-tooltip-path
        aria-label={path}
        className="mt-1 break-all font-mono text-[11px] leading-4 text-fg-muted"
      >
        {compactPath(path)}
      </div>
    </div>,
    document.body,
  );
}

export function usePathTooltip() {
  const anchorRef = useRef<HTMLDivElement>(null);
  const tooltipId = useId();
  const timerRef = useRef<number | null>(null);
  const detachPressRef = useRef<(() => void) | null>(null);
  const [tooltipOpen, setTooltipOpen] = useState(false);

  const hideTooltip = useCallback(() => {
    if (timerRef.current != null) window.clearTimeout(timerRef.current);
    timerRef.current = null;
    detachPressRef.current?.();
    detachPressRef.current = null;
    setTooltipOpen(false);
  }, []);

  const showTooltipSoon = useCallback(() => {
    if (tooltipOpen || timerRef.current != null) return;
    // A press ANYWHERE cancels both the pending timer and an open tip: a
    // click either opens the row's target (often a full-screen preview
    // that covers the stationary pointer, so no mouseleave ever follows —
    // the armed timer would pop the tip on top of it) or interacts
    // somewhere else. Either way the tip is stale from that moment.
    if (!detachPressRef.current) {
      const cancelOnPress = () => hideTooltip();
      window.addEventListener("pointerdown", cancelOnPress, true);
      detachPressRef.current = () =>
        window.removeEventListener("pointerdown", cancelOnPress, true);
    }
    timerRef.current = window.setTimeout(() => {
      timerRef.current = null;
      setTooltipOpen(true);
    }, TOOLTIP_DELAY_MS);
  }, [tooltipOpen, hideTooltip]);

  useEffect(() => {
    return () => {
      if (timerRef.current != null) window.clearTimeout(timerRef.current);
      timerRef.current = null;
      // Also NULL the ref: `detachPressRef.current` non-null must always
      // mean "listener attached", or a remounted instance (StrictMode)
      // would skip re-attaching and silently lose press-cancel.
      detachPressRef.current?.();
      detachPressRef.current = null;
    };
  }, []);

  return { anchorRef, tooltipId, tooltipOpen, hideTooltip, showTooltipSoon };
}

export function Row({
  path,
  dropDir,
  dropTarget,
  depth,
  icon,
  extraIcon,
  name,
  nameSlot,
  detail,
  symlink,
  loading,
  selected,
  decoration,
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
  /** Replaces the name text (inline rename editor). */
  nameSlot?: React.ReactNode;
  detail?: string;
  symlink?: boolean;
  loading?: boolean;
  selected?: boolean;
  decoration?: GitDecoration;
  onClick: () => void;
  actions?: React.ReactNode;
}) {
  const {
    anchorRef: rowRef,
    tooltipId,
    tooltipOpen,
    hideTooltip,
    showTooltipSoon,
  } = usePathTooltip();

  return (
    <div
      ref={rowRef}
      role="treeitem"
      tabIndex={-1}
      aria-selected={selected}
      aria-describedby={tooltipOpen ? tooltipId : undefined}
      data-path={path}
      data-dropdir={dropDir ?? undefined}
      onMouseEnter={showTooltipSoon}
      onMouseLeave={hideTooltip}
      onFocusCapture={showTooltipSoon}
      onBlurCapture={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) hideTooltip();
      }}
      onClick={onClick}
      className={`group relative flex w-full cursor-pointer items-center gap-1.5 px-3 py-[5px] text-left transition-colors ${
        selected ? "bg-bg2 " : "hover:bg-bg2/70"
      } ${dropTarget ? "bg-mint/10" : ""}`}
      style={{ paddingLeft: 12 + depth * 14 }}
    >
      <span className="grid w-3.5 shrink-0 place-items-center text-fg-muted">{icon}</span>
      <span className="shrink-0 text-fg-muted">{extraIcon}</span>
      {nameSlot ? (
        <span className="min-w-0 flex-1">{nameSlot}</span>
      ) : (
        <span
          className={`min-w-0 flex-1 truncate font-mono text-[13px] ${
            decoration ? DECORATION_CLASSES[decoration.tone] : "text-fg"
          }`}
        >
          {name}
          {symlink && <span className="text-fg-muted"> ⇢</span>}
        </span>
      )}
      {(decoration || loading || detail) && (
        <span
          className={`flex shrink-0 items-center gap-1.5 transition-opacity ${
            actions ? "group-hover:opacity-0" : ""
          }`}
        >
          {decoration && (
            <span
              data-git-status={decoration.label}
              aria-label={decoration.title}
              className={`w-3.5 text-center font-mono text-[11px] font-semibold ${DECORATION_CLASSES[decoration.tone]}`}
            >
              {decoration.label}
            </span>
          )}
          {loading ? (
            <span className="font-mono text-[11px] text-mint">…</span>
          ) : (
            detail && <span className="font-mono text-[11px] text-fg-muted">{detail}</span>
          )}
        </span>
      )}
      {actions && (
        <span className="pointer-events-none absolute right-2 flex items-center gap-0.5 bg-bg2 pl-2 opacity-0 transition-opacity group-hover:pointer-events-auto group-hover:opacity-100">
          {actions}
        </span>
      )}
      {tooltipOpen && typeof document !== "undefined" && (
        <PathTooltip
          anchor={rowRef}
          id={tooltipId}
          name={name}
          path={path}
          onDismiss={hideTooltip}
        />
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
