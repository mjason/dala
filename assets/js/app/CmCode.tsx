import React, { useEffect, useRef } from "react";
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, drawSelection } from "@codemirror/view";
import { defaultKeymap } from "@codemirror/commands";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { dalaTheme } from "./cm/theme";
import { languageExtension } from "./cm/languages";
import { lspExtensionsFor } from "./cm/lsp";
import { findOnModF } from "./cm/findOnModF";

type Props = {
  content: string;
  filename: string;
  wrap: boolean;
  /** Absolute path: enables read-only LSP (hover docs + diagnostics). */
  lspPath?: string;
};

/**
 * Read-only syntax-highlighted code view (file previews). CodeMirror's
 * viewport rendering keeps large files smooth, and Ctrl/Cmd+F searches
 * within the file.
 */
export default function CmCode({ content, filename, wrap, lspPath }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const wrapCompartment = useRef(new Compartment());
  const languageCompartment = useRef(new Compartment());
  const lspCompartment = useRef(new Compartment());

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const view = new EditorView({
      state: EditorState.create({
        doc: content,
        extensions: [
          EditorState.readOnly.of(true),
          EditorView.editable.of(false),
          lineNumbers(),
          drawSelection(),
          highlightSelectionMatches(),
          search({ top: false }),
          keymap.of([...searchKeymap, ...defaultKeymap]),
          wrapCompartment.current.of([]),
          languageCompartment.current.of([]),
          lspCompartment.current.of([]),
          dalaTheme,
        ],
      }),
      parent: host,
    });
    viewRef.current = view;
    // Focus so keyboard scroll and Ctrl/Cmd+F work the moment the preview opens
    // (the editing CodeEditor already does this); findOnModF covers the case
    // where focus later moves to a toolbar button.
    view.focus();
    const stopFind = findOnModF(view);

    return () => {
      stopFind();
      viewRef.current = null;
      view.destroy();
    };
    // Content identity changes recreate via the effect below instead.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const current = view.state.doc.toString();
    if (current !== content) {
      view.dispatch({ changes: { from: 0, to: current.length, insert: content } });
    }
  }, [content]);

  useEffect(() => {
    viewRef.current?.dispatch({
      effects: wrapCompartment.current.reconfigure(wrap ? EditorView.lineWrapping : []),
    });
  }, [wrap]);

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      const language = await languageExtension(filename);
      if (cancelled) return;
      viewRef.current?.dispatch({
        effects: languageCompartment.current.reconfigure(language ?? []),
      });
    })();

    return () => {
      cancelled = true;
    };
  }, [filename]);

  // Hover docs + diagnostics in previews too — reading code benefits from
  // the docs as much as writing it (readOnly: completion stays off).
  useEffect(() => {
    let cancelled = false;

    void (async () => {
      if (!lspPath) return;
      try {
        const extensions = await lspExtensionsFor(lspPath, true);
        if (cancelled || !extensions) return;
        viewRef.current?.dispatch({
          effects: lspCompartment.current.reconfigure(extensions),
        });
      } catch {
        // previews work fine without LSP
      }
    })();

    return () => {
      cancelled = true;
      viewRef.current?.dispatch({
        effects: lspCompartment.current.reconfigure([]),
      });
    };
  }, [lspPath]);

  // The absolute box gives CodeMirror a *definite* height: percentage
  // heights resolve to auto inside max-h/auto-height windows on Chromium,
  // which lets .cm-editor grow to its content and kills scrolling.
  return (
    <div className="relative min-h-0 flex-1 overflow-hidden">
      <div ref={hostRef} className="absolute inset-0" />
    </div>
  );
}
