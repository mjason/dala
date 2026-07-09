import React, { useEffect, useMemo, useState } from "react";
import { Text } from "@codemirror/state";
import { Chunk } from "@codemirror/merge";
import { buildLinesPatch } from "./patchBuilder";
import type { ChunkLines } from "./patchBuilder";
import { lineAt } from "./CmDiff";
import type { ChunkAction } from "./CmDiff";
import { useI18n } from "./i18n";

type Props = {
  oldText: string;
  newText: string;
  filename: string;
  wrap: boolean;
  actions: ChunkAction[];
};

type Selection = { removed: Set<number>; added: Set<number> };

const CONTEXT = 3;

function docOf(text: string): Text {
  return Text.of(text.split("\n"));
}

/**
 * Fork's line-level staging: every changed line gets a checkbox, and each
 * chunk applies only the selected lines (unselected removals become context,
 * unselected additions are dropped — lazygit semantics via buildLinesPatch).
 */
export default function LineSelectDiff({ oldText, newText, filename, wrap, actions }: Props) {
  const { t } = useI18n();

  const chunks = useMemo(() => {
    const docA = docOf(oldText);
    const docB = docOf(newText);
    return Chunk.build(docA, docB).map((chunk) => ({
      lines: {
        fromA: lineAt(docA, chunk.fromA),
        toA: lineAt(docA, chunk.toA),
        fromB: lineAt(docB, chunk.fromB),
        toB: lineAt(docB, chunk.toB),
      } satisfies ChunkLines,
    }));
  }, [oldText, newText]);

  const oldLines = useMemo(() => splitLines(oldText), [oldText]);
  const newLines = useMemo(() => splitLines(newText), [newText]);

  const [selections, setSelections] = useState<Map<number, Selection>>(new Map());

  // The documents change after every applied patch; stale line indexes must
  // not survive that.
  useEffect(() => {
    setSelections(new Map());
  }, [oldText, newText]);

  const selectionOf = (index: number): Selection =>
    selections.get(index) ?? { removed: new Set(), added: new Set() };

  const toggle = (index: number, side: "removed" | "added", line: number) => {
    setSelections((prev) => {
      const next = new Map(prev);
      const current = next.get(index) ?? { removed: new Set<number>(), added: new Set<number>() };
      const updated = { removed: new Set(current.removed), added: new Set(current.added) };
      if (updated[side].has(line)) updated[side].delete(line);
      else updated[side].add(line);
      next.set(index, updated);
      return next;
    });
  };

  const setAll = (index: number, chunk: ChunkLines, selected: boolean) => {
    setSelections((prev) => {
      const next = new Map(prev);
      if (!selected) {
        next.set(index, { removed: new Set(), added: new Set() });
      } else {
        next.set(index, {
          removed: new Set(range(chunk.toA - chunk.fromA)),
          added: new Set(range(chunk.toB - chunk.fromB)),
        });
      }
      return next;
    });
  };

  if (chunks.length === 0) {
    return (
      <div className="px-4 py-6 text-center font-mono text-xs text-fg-muted">{t("noChanges")}</div>
    );
  }

  return (
    <div data-line-select className="flex flex-col">
      {chunks.map(({ lines }, index) => {
        const selection = selectionOf(index);
        const count = selection.removed.size + selection.added.size;
        const total = lines.toA - lines.fromA + (lines.toB - lines.fromB);
        const patchFor = (reverse: boolean) =>
          buildLinesPatch(filename, oldText, newText, lines, selection, { reverse });

        return (
          <section key={index} data-line-chunk={index} className="border-b border-line last:border-b-0">
            <header className="flex items-center gap-2 bg-bg2/60 px-3 py-1">
              <label className="flex cursor-pointer items-center gap-2 font-mono text-[11px] italic text-[#7fd0d0]">
                <input
                  type="checkbox"
                  checked={count === total && total > 0}
                  onChange={(e) => setAll(index, lines, e.target.checked)}
                  className="h-3 w-3 accent-[#4cc38a]"
                  title={t("selectAllLines")}
                />
                <span>
                  @@ −{lines.fromA},{lines.toA - lines.fromA} +{lines.fromB},{lines.toB - lines.fromB} @@
                </span>
              </label>
              <div className="flex-1" />
              <span className="font-mono text-[10px] text-fg-muted">
                {count}/{total}
              </span>
            </header>

            <table className="w-full border-collapse font-mono text-xs leading-5">
              <tbody>
                <ContextRows lines={oldLines} chunk={lines} where="before" wrap={wrap} />
                {rangeLines(oldLines, lines.fromA, lines.toA).map((text, i) => (
                  <SelectableRow
                    key={`d${i}`}
                    kind="del"
                    text={text}
                    no={lines.fromA + i}
                    checked={selection.removed.has(i)}
                    onToggle={() => toggle(index, "removed", i)}
                    wrap={wrap}
                  />
                ))}
                {rangeLines(newLines, lines.fromB, lines.toB).map((text, i) => (
                  <SelectableRow
                    key={`a${i}`}
                    kind="add"
                    text={text}
                    no={lines.fromB + i}
                    checked={selection.added.has(i)}
                    onToggle={() => toggle(index, "added", i)}
                    wrap={wrap}
                  />
                ))}
                <ContextRows lines={oldLines} chunk={lines} where="after" wrap={wrap} />
              </tbody>
            </table>

            <div className="flex gap-2 border-t border-line bg-bg2/60 px-3 py-1.5">
              {actions.map((action, a) => (
                <button
                  key={a}
                  data-line-action={action.kind}
                  disabled={count === 0}
                  onClick={() =>
                    action.onClick({ forward: patchFor(false), reverse: patchFor(true) }, "lines")
                  }
                  className={`rounded border px-2 py-0.5 font-mono text-[10px] transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
                    action.kind === "primary"
                      ? "border-mint/50 text-mint enabled:hover:border-mint enabled:hover:bg-mint/10"
                      : "border-line text-fg-muted enabled:hover:border-[#e5716e]/60 enabled:hover:bg-[#e5716e]/10 enabled:hover:text-[#e5716e]"
                  }`}
                >
                  {action.lineLabel ?? action.label} ({count})
                </button>
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}

function splitLines(text: string): string[] {
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

function range(n: number): number[] {
  return Array.from({ length: n }, (_, i) => i);
}

function rangeLines(lines: string[], from: number, to: number): string[] {
  return lines.slice(from - 1, to - 1);
}

function ContextRows({
  lines,
  chunk,
  where,
  wrap,
}: {
  lines: string[];
  chunk: ChunkLines;
  where: "before" | "after";
  wrap: boolean;
}) {
  const count =
    where === "before"
      ? Math.min(CONTEXT, chunk.fromA - 1)
      : Math.min(CONTEXT, lines.length - (chunk.toA - 1));
  const startOld = where === "before" ? chunk.fromA - count : chunk.toA;
  const startNew = where === "before" ? chunk.fromB - count : chunk.toB;

  return (
    <>
      {range(count).map((i) => (
        <tr key={i}>
          <td className="w-6" />
          <LineNo no={startOld + i} />
          <LineNo no={startNew + i} />
          <td
            className={`w-full pr-3 text-fg-muted ${wrap ? "whitespace-pre-wrap [overflow-wrap:anywhere]" : "whitespace-pre"}`}
          >
            {lines[startOld + i - 1] || " "}
          </td>
        </tr>
      ))}
    </>
  );
}

function SelectableRow({
  kind,
  text,
  no,
  checked,
  onToggle,
  wrap,
}: {
  kind: "del" | "add";
  text: string;
  no: number;
  checked: boolean;
  onToggle: () => void;
  wrap: boolean;
}) {
  const bg = kind === "add" ? "bg-[#5fbf87]/[0.11]" : "bg-[#e5716e]/[0.10]";
  const sign = kind === "add" ? "+" : "−";
  const signColor = kind === "add" ? "text-[#5fbf87]" : "text-[#e5716e]";

  return (
    <tr
      className={`cursor-pointer ${bg} ${checked ? "outline outline-1 -outline-offset-1 outline-mint/40" : ""}`}
      onClick={onToggle}
      data-line-row={kind}
      data-selected={checked || undefined}
    >
      <td className="w-6 text-center align-middle">
        <input
          type="checkbox"
          checked={checked}
          onChange={onToggle}
          onClick={(e) => e.stopPropagation()}
          className="h-3 w-3 accent-[#4cc38a]"
        />
      </td>
      <LineNo no={kind === "del" ? no : null} />
      <LineNo no={kind === "add" ? no : null} />
      <td className={`w-full pr-3 text-fg ${wrap ? "whitespace-pre-wrap [overflow-wrap:anywhere]" : "whitespace-pre"}`}>
        <span className={`select-none ${signColor}`}>{sign} </span>
        {text || " "}
      </td>
    </tr>
  );
}

function LineNo({ no }: { no: number | null }) {
  return (
    <td className="w-10 min-w-10 select-none border-r border-line/40 px-1.5 text-right align-top text-[11px] text-fg-muted/60">
      {no ?? ""}
    </td>
  );
}
