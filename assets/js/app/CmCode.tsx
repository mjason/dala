import React, { useEffect, useRef } from "react";
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, drawSelection } from "@codemirror/view";
import { defaultKeymap } from "@codemirror/commands";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { dalaTheme } from "./cm/theme";
import { useTheme } from "./theme";
import { languageExtension } from "./cm/languages";
import { lspExtensionsFor } from "./cm/lsp";

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
  const themeCompartment = useRef(new Compartment());
  const { resolvedTheme } = useTheme();
  const appliedThemeRef = useRef(resolvedTheme);

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
          themeCompartment.current.of(dalaTheme(resolvedTheme)),
        ],
      }),
      parent: host,
    });
    viewRef.current = view;

    return () => {
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
    if (appliedThemeRef.current === resolvedTheme) return;
    appliedThemeRef.current = resolvedTheme;
    viewRef.current?.dispatch({
      effects: themeCompartment.current.reconfigure(dalaTheme(resolvedTheme)),
    });
  }, [resolvedTheme]);

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
