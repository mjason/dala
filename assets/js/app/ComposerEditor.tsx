import React, { useEffect, useRef } from "react";
import { EditorState, Compartment, Prec } from "@codemirror/state";
import { EditorView, keymap, drawSelection, placeholder as cmPlaceholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentMore, indentLess } from "@codemirror/commands";
import { markdown, insertNewlineContinueMarkup } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { dalaTheme } from "./cm/theme";

type Props = {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  /** Bumped on user-initiated opens: focus and put the cursor at the END. */
  focusNonce: number;
  /** Enter (no shift): send. Return true when handled. */
  onEnter: () => void;
  onEscape: () => void;
  /** Mention-menu hooks; return true to swallow the key. */
  onArrow: (dir: 1 | -1) => boolean;
  onPick: () => boolean;
  /** Cursor/document sync for @-mention tracking. */
  onCursor: (text: string, pos: number) => void;
};

/**
 * The composer's editor: CodeMirror with Markdown + fenced-code syntax
 * highlighting for every bundled language (```python and friends), history,
 * and IME-safe key handling. Grows with content up to ~9 lines.
 */
export default function ComposerEditor({
  value,
  onChange,
  placeholder,
  focusNonce,
  onEnter,
  onEscape,
  onArrow,
  onPick,
  onCursor,
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const placeholderCompartment = useRef(new Compartment());
  // The latest callbacks, visible to the once-registered keymap.
  const cbs = useRef({ onEnter, onEscape, onArrow, onPick, onChange, onCursor });
  cbs.current = { onEnter, onEscape, onArrow, onPick, onChange, onCursor };

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const view = new EditorView({
      state: EditorState.create({
        doc: value,
        extensions: [
          history(),
          drawSelection(),
          EditorView.lineWrapping,
          markdown({ codeLanguages: languages }),
          placeholderCompartment.current.of(cmPlaceholder(placeholder)),
          Prec.highest(
            keymap.of([
              {
                key: "ArrowDown",
                run: (v) => !v.composing && cbs.current.onArrow(1),
              },
              {
                key: "ArrowUp",
                run: (v) => !v.composing && cbs.current.onArrow(-1),
              },
              {
                // Menu open: Tab picks. Otherwise: a professional editor's
                // Tab — indent the selection/line.
                key: "Tab",
                run: (v) => {
                  if (v.composing) return false;
                  if (cbs.current.onPick()) return true;
                  return indentMore(v);
                },
                shift: indentLess,
              },
              {
                // Enter is a newline (with markdown list/quote continuation),
                // like an editor — sending is Shift+Enter.
                key: "Enter",
                run: (v) => {
                  if (v.composing) return false;
                  if (cbs.current.onPick()) return true;
                  return insertNewlineContinueMarkup(v);
                },
              },
              {
                key: "Shift-Enter",
                run: (v) => {
                  if (v.composing) return false;
                  cbs.current.onEnter();
                  return true;
                },
              },
              {
                key: "Escape",
                run: () => {
                  cbs.current.onEscape();
                  return true;
                },
              },
            ]),
          ),
          keymap.of([...defaultKeymap, ...historyKeymap]),
          EditorView.updateListener.of((update) => {
            if (update.docChanged) {
              cbs.current.onChange(update.state.doc.toString());
            }
            if (update.docChanged || update.selectionSet) {
              cbs.current.onCursor(
                update.state.doc.toString(),
                update.state.selection.main.head,
              );
            }
          }),
          dalaTheme,
          EditorView.theme({
            "&": { maxHeight: "13.5rem", fontSize: "14px" },
            ".cm-scroller": { fontFamily: "inherit", lineHeight: "1.5" },
            ".cm-content": { padding: "6px 10px" },
          }),
        ],
      }),
      parent: host,
    });
    viewRef.current = view;

    return () => {
      viewRef.current = null;
      view.destroy();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // External value changes (mention pick, attach, session switch, send-clear):
  // replace the document and park the cursor at the end.
  useEffect(() => {
    const view = viewRef.current;
    if (!view || view.state.doc.toString() === value) return;
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: value },
      selection: { anchor: value.length },
    });
  }, [value]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    view.dispatch({
      effects: placeholderCompartment.current.reconfigure(cmPlaceholder(placeholder)),
    });
  }, [placeholder]);

  // User-initiated opens focus with the cursor at the END of the draft.
  useEffect(() => {
    const view = viewRef.current;
    if (!view || focusNonce === 0) return;
    view.focus();
    view.dispatch({ selection: { anchor: view.state.doc.length } });
  }, [focusNonce]);

  return (
    <div
      ref={hostRef}
      id="composer-editor"
      className="min-h-[2.4rem] w-full overflow-hidden rounded-md border border-line bg-bg0 font-mono transition-colors focus-within:border-mint/60"
    />
  );
}
