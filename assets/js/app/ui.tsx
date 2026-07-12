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
  return <textarea ref={ref} {...props} className={cx(inputClass, "resize-y", className)} />;
});

export const Select = React.forwardRef<
  HTMLSelectElement,
  React.SelectHTMLAttributes<HTMLSelectElement>
>(function Select({ className, ...props }, ref) {
  return <select ref={ref} {...props} className={cx(inputClass, className)} />;
});
