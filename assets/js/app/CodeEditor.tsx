import React, { useEffect, useRef } from "react";
import { EditorState, Compartment } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  drawSelection,
  dropCursor,
  rectangularSelection,
  crosshairCursor,
} from "@codemirror/view";
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from "@codemirror/commands";
import { bracketMatching, indentOnInput, indentUnit } from "@codemirror/language";
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { dalaTheme } from "./cm/theme";
import { languageExtension } from "./cm/languages";

type Props = {
  value: string;
  onChange: (value: string) => void;
  onSave: () => void;
  wrap: boolean;
  filename?: string;
};

/**
 * The file editor: CodeMirror 6 with syntax highlighting (lazy-loaded
 * per-language grammars), bracket matching, in-editor search (Ctrl/Cmd+F),
 * indent-aware Tab/Enter and Cmd/Ctrl+S to save.
 */
export default function CodeEditor({ value, onChange, onSave, wrap, filename }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const onChangeRef = useRef(onChange);
  const onSaveRef = useRef(onSave);
  onChangeRef.current = onChange;
  onSaveRef.current = onSave;

  const wrapCompartment = useRef(new Compartment());
  const languageCompartment = useRef(new Compartment());

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const state = EditorState.create({
      doc: value,
      extensions: [
        lineNumbers(),
        highlightActiveLine(),
        highlightActiveLineGutter(),
        history(),
        drawSelection(),
        dropCursor(),
        rectangularSelection(),
        crosshairCursor(),
        indentOnInput(),
        indentUnit.of("  "),
        bracketMatching(),
        closeBrackets(),
        highlightSelectionMatches(),
        search({ top: false }),
        keymap.of([
          {
            key: "Mod-s",
            preventDefault: true,
            run: () => {
              onSaveRef.current();
              return true;
            },
          },
          ...closeBracketsKeymap,
          ...defaultKeymap,
          ...searchKeymap,
          ...historyKeymap,
          indentWithTab,
        ]),
        wrapCompartment.current.of([]),
        languageCompartment.current.of([]),
        dalaTheme,
        EditorView.updateListener.of((update) => {
          if (update.docChanged) onChangeRef.current(update.state.doc.toString());
        }),
      ],
    });

    const view = new EditorView({ state, parent: host });
    viewRef.current = view;
    view.focus();

    return () => {
      viewRef.current = null;
      view.destroy();
    };
    // The view lives for the component's lifetime; value/wrap/filename are
    // synchronized through the effects below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // External value changes (e.g. a reload) — do not clobber user edits.
  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const current = view.state.doc.toString();
    if (current !== value) {
      view.dispatch({ changes: { from: 0, to: current.length, insert: value } });
    }
  }, [value]);

  useEffect(() => {
    viewRef.current?.dispatch({
      effects: wrapCompartment.current.reconfigure(wrap ? EditorView.lineWrapping : []),
    });
  }, [wrap]);

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      const language = filename ? await languageExtension(filename) : null;
      if (cancelled) return;
      viewRef.current?.dispatch({
        effects: languageCompartment.current.reconfigure(language ?? []),
      });
    })();

    return () => {
      cancelled = true;
    };
  }, [filename]);

  // See CmCode: the absolute box keeps CodeMirror's height definite so its
  // own scroller works inside auto-height windows on Chromium.
  return (
    <div id="code-editor" className="relative min-h-0 flex-1 overflow-hidden bg-bg0">
      <div ref={hostRef} className="absolute inset-0" />
    </div>
  );
}
