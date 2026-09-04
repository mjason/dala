import React from "react";
import { FieldLabel } from "../ui";

export type SegmentedOption<T extends string> = { value: T; label: string };

/**
 * A labelled row of mutually exclusive choices (theme, cursor style, local
 * echo). The three of them were the same twelve lines of Tailwind copied
 * around; the only thing that ever differed is the `data-*` attribute the
 * tests select on.
 */
export default function Segmented<T extends string>({
  id,
  label,
  hint,
  options,
  value,
  dataAttr,
  onChange,
}: {
  id: string;
  label: string;
  hint?: string;
  options: SegmentedOption<T>[];
  value: T;
  /** Per-option marker attribute, e.g. "data-cursor-style". */
  dataAttr: string;
  onChange: (value: T) => void;
}) {
  return (
    <div className="space-y-1.5">
      <FieldLabel>{label}</FieldLabel>
      <div
        id={id}
        className="grid gap-0.5 rounded-lg border border-line bg-bg2 p-0.5"
        style={{ gridTemplateColumns: `repeat(${options.length}, minmax(0, 1fr))` }}
      >
        {options.map((option) => (
          <button
            key={option.value}
            {...{ [dataAttr]: option.value }}
            aria-pressed={value === option.value}
            onClick={() => onChange(option.value)}
            className={`whitespace-nowrap rounded-md px-2.5 py-1 text-xs transition-colors ${
              value === option.value
                ? "bg-bg0 font-medium text-mint shadow-sm"
                : "text-fg-muted hover:text-fg"
            }`}
          >
            {option.label}
          </button>
        ))}
      </div>
      {hint && <span className="block text-xs leading-5 text-fg-muted/80">{hint}</span>}
    </div>
  );
}
