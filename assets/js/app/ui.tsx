/**
 * Shared form-control primitives — the single source of truth for input
 * visuals. A border/focus/size tweak lands HERE once instead of being
 * chased across seven hand-copied Tailwind strings (which had already
 * drifted: text-[13px] vs text-[15px], focus:ring sometimes missing).
 *
 * Deviations: pass `className` for layout concerns (width, margin). Do
 * not re-specify colors/borders/focus at call sites — change them here.
 */
import React from "react";

export function cx(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(" ");
}

export const inputClass =
  "w-full rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[13px] text-fg outline-none transition-colors focus:border-mint/60";

export const TextInput = React.forwardRef<
  HTMLInputElement,
  React.InputHTMLAttributes<HTMLInputElement>
>(function TextInput({ className, ...props }, ref) {
  return <input ref={ref} {...props} className={cx(inputClass, className)} />;
});

export const TextArea = React.forwardRef<
  HTMLTextAreaElement,
  React.TextareaHTMLAttributes<HTMLTextAreaElement>
>(function TextArea({ className, ...props }, ref) {
  // Tailwind resolves conflicts by stylesheet order (resize-y is emitted
  // after resize-none), so a caller's resize choice must replace the
  // default instead of being appended next to it.
  const resize = /(?:^|\s)resize-/.test(className ?? "") ? null : "resize-y";
  return <textarea ref={ref} {...props} className={cx(inputClass, resize, className)} />;
});

export const Select = React.forwardRef<
  HTMLSelectElement,
  React.SelectHTMLAttributes<HTMLSelectElement>
>(function Select({ className, ...props }, ref) {
  return <select ref={ref} {...props} className={cx(inputClass, className)} />;
});

// ------------------------------------------------- modal/form companions

/** Muted label above a form control. */
export function FieldLabel({ children }: { children: React.ReactNode }) {
  return <span className="text-xs text-fg-muted">{children}</span>;
}

/** Small right-aligned monospace value chip next to a control label. */
export function ValueChip({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded border border-line bg-bg0 px-1.5 py-0.5 font-mono text-[11px] tabular-nums text-fg">
      {children}
    </span>
  );
}

/** iOS-style switch; keeps a hidden checkbox for the stable input id. */
export function Toggle({
  id,
  checked,
  onChange,
}: {
  id: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className={`relative h-5 w-9 shrink-0 rounded-full transition-colors duration-150 ${
        checked ? "bg-mint" : "bg-bg2 ring-1 ring-inset ring-line"
      }`}
    >
      <input id={id} type="checkbox" checked={checked} readOnly className="sr-only" />
      <span
        className={`absolute top-0.5 left-0.5 h-4 w-4 rounded-full transition-transform duration-150 ${
          checked ? "translate-x-4 bg-black/80" : "bg-fg-muted"
        }`}
      />
    </button>
  );
}
