import React, { useEffect, useState } from "react";
import type { BarKey } from "./touchKeys";

/** True on touch-first devices: the PRIMARY pointer is coarse (phones,
 * tablets). A desktop with a touchscreen keeps its fine mouse pointer and
 * gets no touch chrome. */
export function useCoarsePointer(): boolean {
  const [coarse, setCoarse] = useState(
    () =>
      typeof window.matchMedia === "function" &&
      window.matchMedia("(pointer: coarse)").matches,
  );
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const query = window.matchMedia("(pointer: coarse)");
    const update = () => setCoarse(query.matches);
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  return coarse;
}

const KEYS: { key: BarKey; label: string }[] = [
  { key: "esc", label: "Esc" },
  { key: "tab", label: "Tab" },
  { key: "up", label: "↑" },
  { key: "down", label: "↓" },
  { key: "left", label: "←" },
  { key: "right", label: "→" },
  { key: "ctrl-c", label: "^C" },
];

type Props = {
  /** Sticky Ctrl latched (owned by App, which also applies it to the next
   * soft-keyboard character). */
  ctrl: boolean;
  onCtrl: () => void;
  onKey: (key: BarKey) => void;
};

/**
 * Slim bar of terminal keys a soft keyboard lacks, shown above the composer
 * strip on touch devices. Every button acts on pointerdown WITH
 * preventDefault: a tap must never move focus off the terminal's hidden
 * textarea, or the soft keyboard would collapse mid-session.
 */
export default function TouchKeyBar({ ctrl, onCtrl, onKey }: Props) {
  const press = (e: React.PointerEvent, run: () => void) => {
    e.preventDefault();
    run();
  };

  // Apple HIG-ish tap targets: every key is at least 40px tall (min-h on
  // the buttons themselves — the bar's top border must not eat into it)
  // with 14px text that reads at arm's length.
  const base =
    "min-h-10 min-w-11 flex-1 rounded-md border px-2 font-mono text-sm transition-colors select-none";

  return (
    <div
      id="touch-key-bar"
      className="flex shrink-0 items-stretch gap-1.5 overflow-x-auto border-t border-line bg-bg1 px-2 py-1"
    >
      {KEYS.slice(0, 2).map(({ key, label }) => (
        <button
          key={key}
          data-key={key}
          onPointerDown={(e) => press(e, () => onKey(key))}
          className={`${base} border-line text-fg-muted active:bg-bg2 active:text-fg`}
        >
          {label}
        </button>
      ))}
      <button
        data-key="ctrl"
        aria-pressed={ctrl}
        onPointerDown={(e) => press(e, onCtrl)}
        className={`${base} ${
          ctrl
            ? "border-mint/60 bg-mint/15 text-mint"
            : "border-line text-fg-muted active:bg-bg2 active:text-fg"
        }`}
      >
        Ctrl
      </button>
      {KEYS.slice(2).map(({ key, label }) => (
        <button
          key={key}
          data-key={key}
          onPointerDown={(e) => press(e, () => onKey(key))}
          className={`${base} border-line text-fg-muted active:bg-bg2 active:text-fg`}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
