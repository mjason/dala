import React, { useEffect, useRef } from "react";
import { EditorState, Compartment, Prec } from "@codemirror/state";
import { EditorView, keymap, drawSelection, placeholder as cmPlaceholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentMore, indentLess } from "@codemirror/commands";
import { markdown, insertNewlineContinueMarkup } from "@codemirror/lang-markdown";
import { collectTransferFiles } from "./pasteFiles";
import { languages } from "@codemirror/language-data";
import { dalaTheme } from "./cm/theme";


type Props = {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  /** CodeMirror key ("Shift-Enter") that sends — customizable in settings. */
  sendKey: string;
  /** Bumped on user-initiated opens: focus and put the cursor at the END. */
  focusNonce: number;
  /** The last nonce already honored (owned by the App — a render-time
   * snapshot, so StrictMode's double effects and remounts both behave):
   * equal values mean "this mount is an auto-open, don't steal focus". */
  focusConsumed: number;
  onFocusConsumed: (nonce: number) => void;
  /** Enter (no shift): send. Return true when handled. */
  onEnter: () => void;
  onEscape: () => void;
  /** Mention-menu hooks; return true to swallow the key. */
  onArrow: (dir: 1 | -1) => boolean;
  onPick: () => boolean;
  /** Cursor/document sync for @-mention tracking. */
  onCursor: (text: string, pos: number) => void;
  /** Local files pasted or dropped into the editor (uploaded by the parent). */
  onFiles: (files: File[]) => void;
};

/**
 * The composer's editor: CodeMirror with Markdown + fenced-code syntax
 * highlighting for every bundled language (```python and friends), history,
 * and IME-safe key handling. Grows with content up to ~9 lines.
 */
type Callbacks = {
  current: {
    onEnter: () => void;
    onEscape: () => void;
    onArrow: (dir: 1 | -1) => boolean;
    onPick: () => boolean;
    onChange: (value: string) => void;
    onCursor: (text: string, pos: number) => void;
    onFiles: (files: File[]) => void;
  };
};

// The send key is customizable, so the keymap lives in a compartment. The
// send entry comes FIRST: bound to plain Enter it must beat the
// newline-with-markdown-continuation entry below it.
function buildKeymap(sendKey: string, cbs: Callbacks) {
  return Prec.highest(
    keymap.of([
      {
        key: sendKey,
        run: (v) => {
          if (v.composing) return false;
          cbs.current.onEnter();
          return true;
        },
      },
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
        // like an editor — sending defaults to Shift+Enter.
        key: "Enter",
        run: (v) => {
          if (v.composing) return false;
          if (cbs.current.onPick()) return true;
          return insertNewlineContinueMarkup(v);
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
  );
}

export default function ComposerEditor({
  value,
  onChange,
  placeholder,
  sendKey,
  focusNonce,
  focusConsumed,
  onFocusConsumed,
  onEnter,
  onEscape,
  onArrow,
  onPick,
  onCursor,
  onFiles,
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const placeholderCompartment = useRef(new Compartment());
  const keymapCompartment = useRef(new Compartment());
  // The latest callbacks, visible to the once-registered keymap.
  const cbs = useRef({ onEnter, onEscape, onArrow, onPick, onChange, onCursor, onFiles });
  cbs.current = { onEnter, onEscape, onArrow, onPick, onChange, onCursor, onFiles };

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
          keymapCompartment.current.of(buildKeymap(sendKey, cbs)),
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
          // Local files pasted or dropped land as uploads, like the terminal.
          EditorView.domEventHandlers({
            paste: (event) => {
              const files = collectTransferFiles(event.clipboardData);
              if (files.length === 0) return false;
              event.preventDefault();
              cbs.current.onFiles(files);
              return true;
            },
            drop: (event) => {
              const files = collectTransferFiles(event.dataTransfer);
              if (files.length === 0) return false;
              event.preventDefault();
              cbs.current.onFiles(files);
              return true;
            },
          }),
          dalaTheme,
          EditorView.theme({
            "&": { fontSize: "14px" },
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

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    view.dispatch({
      effects: keymapCompartment.current.reconfigure(buildKeymap(sendKey, cbs)),
    });
  }, [sendKey]);

  // User-initiated opens focus with the cursor at the END of the draft.
  useEffect(() => {
    const view = viewRef.current;
    if (!view || focusNonce === 0 || focusNonce === focusConsumed) return;
    onFocusConsumed(focusNonce);
    view.focus();
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    // focusConsumed is a render-time snapshot on purpose (see Props).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusNonce]);

  return (
    <div
      ref={hostRef}
      id="composer-editor"
      // Fixed height: growing per typed line would reflow the terminal (and
      // its TUI) on every wrap — resize exactly once per open/close.
      className="h-[7.5rem] w-full overflow-hidden rounded-md border border-line bg-bg0 font-mono transition-colors focus-within:border-mint/60"
    />
  );
}
