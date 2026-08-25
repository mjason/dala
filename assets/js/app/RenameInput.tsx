import React, { useRef } from "react";
import { cx } from "./ui";

/**
 * Inline rename field, shared by the session sidebar and the file drawer.
 *
 * Enter commits and then blurs; blur commits too — the first outcome wins.
 * Escape cancels and is swallowed (stopPropagation + preventDefault): the
 * editor is not a "window" on the Esc stack, so it must not pop one.
 *
 * Visuals paint without layout so the field can occupy EXACTLY the box the
 * static label occupied (callers pass the geometry): transparent background
 * with a mint ring — reads as "editing here" without the heavy dark well.
 */
export function RenameInput({
  name,
  label,
  className,
  onCommit,
  onCancel,
  ...rest
}: {
  name: string;
  label: string;
  className?: string;
  onCommit: (name: string) => void;
  onCancel: () => void;
} & Omit<
  React.InputHTMLAttributes<HTMLInputElement>,
  "defaultValue" | "onBlur" | "onKeyDown" | "className" | "aria-label"
>) {
  const settled = useRef(false);
  const commit = (value: string) => {
    if (settled.current) return;
    settled.current = true;
    onCommit(value.trim());
  };
  const cancel = () => {
    if (settled.current) return;
    settled.current = true;
    onCancel();
  };

  return (
    <input
      aria-label={label}
      defaultValue={name}
      autoFocus
      spellCheck={false}
      onFocus={(e) => e.currentTarget.select()}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          commit(e.currentTarget.value);
        } else if (e.key === "Escape") {
          e.preventDefault();
          cancel();
        }
      }}
      onBlur={(e) => commit(e.currentTarget.value)}
      className={cx(
        "rounded bg-transparent text-fg caret-mint outline-none ring-1 ring-mint/60 selection:bg-mint/30",
        className,
      )}
      {...rest}
    />
  );
}
