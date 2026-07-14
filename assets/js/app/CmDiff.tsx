import React, { useEffect, useRef, useState } from "react";
import { Compartment, EditorState, StateField, StateEffect } from "@codemirror/state";
import type { Extension, Text } from "@codemirror/state";
import { Decoration, EditorView, lineNumbers, WidgetType } from "@codemirror/view";
import type { DecorationSet } from "@codemirror/view";
import { getChunks, getOriginalDoc, MergeView, unifiedMergeView } from "@codemirror/merge";
import { dalaTheme } from "./cm/theme";
import { languageExtension } from "./cm/languages";
import { buildChunkPatch } from "./patchBuilder";
import type { ChunkLines } from "./patchBuilder";
import { useTheme } from "./theme";

export type ChunkPatch = { forward: string; reverse: string };

export type ChunkAction = {
  label: string;
  /** Label used by the line-selection mode ("Stage selected lines" …). */
  lineLabel?: string;
  kind: "primary" | "danger";
  onClick: (patch: ChunkPatch, source?: "hunk" | "lines") => void;
};

type Props = {
  oldText: string;
  newText: string;
  mode: "inline" | "split";
  wrap: boolean;
  filename: string;
  /** Per-hunk buttons (Fork-style stage/unstage/discard). */
  chunkActions?: ChunkAction[];
};

/**
 * Syntax-highlighted diff for one file, driven by the full old/new contents
 * (VS Code style): character-level change marks, collapsed unchanged regions
 * and real line numbers, via @codemirror/merge. With `chunkActions`, every
 * change block gets its own action buttons, each backed by a minimal unified
 * patch for that hunk.
 */
export default function CmDiff({ oldText, newText, mode, wrap, filename, chunkActions }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewsRef = useRef<EditorView[]>([]);
  const themeCompartment = useRef(new Compartment());
  const { resolvedTheme } = useTheme();
  const resolvedThemeRef = useRef(resolvedTheme);
  resolvedThemeRef.current = resolvedTheme;
  const appliedThemeRef = useRef(resolvedTheme);
  const [language, setLanguage] = useState<Extension | null | "loading">("loading");

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      const loaded = await languageExtension(filename);
      if (!cancelled) setLanguage(loaded);
    })();

    return () => {
      cancelled = true;
    };
  }, [filename]);

  useEffect(() => {
    const host = hostRef.current;
    if (!host || language === "loading") return;

    const shared: Extension[] = [
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      lineNumbers(),
      themeCompartment.current.of(dalaTheme(resolvedThemeRef.current)),
      ...(wrap ? [EditorView.lineWrapping] : []),
      ...(language ? [language] : []),
    ];
    const collapseUnchanged = { margin: 3, minSize: 4 };

    let destroy: () => void;

    if (mode === "split") {
      const view = new MergeView({
        parent: host,
        a: { doc: oldText, extensions: shared },
        b: { doc: newText, extensions: [...shared, hunkButtonsField] },
        gutter: true,
        highlightChanges: true,
        collapseUnchanged,
      });
      viewsRef.current = [view.a, view.b];

      if (chunkActions && chunkActions.length > 0) {
        attachHunkButtons(view.b, filename, oldText, newText, chunkActions, view.a.state.doc);
      }

      destroy = () => view.destroy();
    } else {
      const view = new EditorView({
        parent: host,
        state: EditorState.create({
          doc: newText,
          extensions: [
            ...shared,
            hunkButtonsField,
            unifiedMergeView({
              original: oldText,
              mergeControls: false,
              gutter: true,
              collapseUnchanged,
            }),
          ],
        }),
      });
      viewsRef.current = [view];

      if (chunkActions && chunkActions.length > 0) {
        attachHunkButtons(view, filename, oldText, newText, chunkActions);
      }

      destroy = () => view.destroy();
    }

    return () => {
      viewsRef.current = [];
      destroy();
    };
  }, [oldText, newText, mode, wrap, language, chunkActions, filename]);

  useEffect(() => {
    if (appliedThemeRef.current === resolvedTheme) return;
    appliedThemeRef.current = resolvedTheme;
    for (const view of viewsRef.current) {
      view.dispatch({
        effects: themeCompartment.current.reconfigure(dalaTheme(resolvedTheme)),
      });
    }
  }, [resolvedTheme]);

  return <div ref={hostRef} data-cm-diff className="min-h-0" />;
}

// --- per-hunk action buttons -------------------------------------------------

const setHunkButtons = StateEffect.define<DecorationSet>();

const hunkButtonsField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setHunkButtons)) return effect.value;
    }
    return value.map(tr.changes);
  },
  provide: (field) => EditorView.decorations.from(field),
});

class HunkButtonsWidget extends WidgetType {
  constructor(
    readonly patch: ChunkPatch,
    readonly actions: ChunkAction[],
  ) {
    super();
  }

  override eq(other: HunkButtonsWidget) {
    return other.patch.forward === this.patch.forward;
  }

  toDOM() {
    const bar = document.createElement("div");
    bar.className = "cm-hunk-actions";
    for (const action of this.actions) {
      const button = document.createElement("button");
      button.textContent = action.label;
      button.className = `cm-hunk-button cm-hunk-button-${action.kind}`;
      button.onmousedown = (e) => e.preventDefault();
      button.onclick = () => action.onClick(this.patch);
      bar.appendChild(button);
    }
    return bar;
  }

  override ignoreEvent() {
    return true;
  }
}

/** 1-based half-open line number for a document offset (chunk boundaries are
 * always at line starts; the document end maps to lines+1 unless a trailing
 * newline already accounts for it). */
export function lineAt(doc: Text, pos: number): number {
  if (pos >= doc.length) {
    const endsWithNewline = doc.length > 0 && doc.sliceString(doc.length - 1) === "\n";
    return endsWithNewline ? doc.lines : doc.lines + 1;
  }
  return doc.lineAt(pos).number;
}

function attachHunkButtons(
  view: EditorView,
  filePath: string,
  oldText: string,
  newText: string,
  actions: ChunkAction[],
  /** The old-side document; defaults to the unified view's original doc. */
  original?: Text,
) {
  const result = getChunks(view.state);
  if (!result) return;

  const originalDoc = original ?? getOriginalDoc(view.state);
  const doc = view.state.doc;
  const decorations = [];

  for (const chunk of result.chunks) {
    const lines: ChunkLines = {
      fromA: lineAt(originalDoc, chunk.fromA),
      toA: lineAt(originalDoc, chunk.toA),
      fromB: lineAt(doc, chunk.fromB),
      toB: lineAt(doc, chunk.toB),
    };
    const patch: ChunkPatch = {
      forward: buildChunkPatch(filePath, oldText, newText, lines),
      reverse: buildChunkPatch(filePath, oldText, newText, lines, { reverse: true }),
    };

    const pos = Math.min(chunk.fromB, doc.length);
    decorations.push(
      Decoration.widget({
        widget: new HunkButtonsWidget(patch, actions),
        block: true,
        side: -10,
      }).range(pos),
    );
  }

  view.dispatch({ effects: setHunkButtons.of(Decoration.set(decorations, true)) });
}
