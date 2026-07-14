import React, { useEffect, useRef } from "react";
import { EditorState, Compartment, Prec } from "@codemirror/state";
import { EditorView, keymap, drawSelection, placeholder as cmPlaceholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentMore, indentLess } from "@codemirror/commands";
import { markdown, insertNewlineContinueMarkup } from "@codemirror/lang-markdown";
import { collectTransferFiles } from "./pasteFiles";
import { languages } from "@codemirror/language-data";
import { dalaTheme } from "./cm/theme";
import { useTheme } from "./theme";
import { composerSizing } from "./composerSize";


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
  /** Fullscreen: fill the host (a flex child) instead of growing to the cap. */
  fullscreen: boolean;
  /** Debounced editor-height changes (auto-grow) — the terminal refits. */
  onResize: () => void;
};

/**
 * The composer's editor: CodeMirror with Markdown + fenced-code syntax
 * highlighting for every bundled language (```python and friends), history,
 * and IME-safe key handling. Grows with content between the old fixed
 * height and a viewport-bounded cap (see composerSize.ts).
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
    onResize: () => void;
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

/**
 * Coarse pointer = touch: bigger type (iOS auto-zoom) and, because of it, a
 * taller floor for the same three lines (see composerSize.ts).
 */
function coarsePointerNow(): boolean {
  return (
    typeof window.matchMedia === "function" && window.matchMedia("(pointer: coarse)").matches
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
  fullscreen,
  onResize,
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const placeholderCompartment = useRef(new Compartment());
  const keymapCompartment = useRef(new Compartment());
  const sizingCompartment = useRef(new Compartment());
  const themeCompartment = useRef(new Compartment());
  const { resolvedTheme } = useTheme();
  const appliedThemeRef = useRef(resolvedTheme);
  // The latest callbacks, visible to the once-registered keymap.
  const cbs = useRef({ onEnter, onEscape, onArrow, onPick, onChange, onCursor, onFiles, onResize });
  cbs.current = { onEnter, onEscape, onArrow, onPick, onChange, onCursor, onFiles, onResize };

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const coarsePointer = coarsePointerNow();

    const view = new EditorView({
      state: EditorState.create({
        doc: value,
        // A mount with an existing draft parks the cursor at the END — where
        // the user left off (user-initiated opens re-assert this via
        // focusNonce, auto-opens just keep it without stealing focus).
        selection: { anchor: value.length },
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
          themeCompartment.current.of(dalaTheme(resolvedTheme)),
          EditorView.theme({
            // 16px on touch devices — iOS Safari auto-zooms the whole page
            // when an editable element with a smaller font gains focus.
            "&": { fontSize: coarsePointer ? "16px" : "14px" },
            ".cm-scroller": { fontFamily: "inherit", lineHeight: "1.5" },
            ".cm-content": { padding: "6px 10px" },
          }),
          sizingCompartment.current.of(
            EditorView.theme(composerSizing(fullscreen, coarsePointer)),
          ),
        ],
      }),
      parent: host,
    });
    viewRef.current = view;

    // A draft that outgrew the box must open showing its END (the cursor).
    // Deferred one tick: CodeMirror applies scroll targets during its
    // measure cycle, which needs the initial layout to exist first.
    let scrollTimer: number | undefined;
    if (value.length > 0) {
      scrollTimer = window.setTimeout(() => {
        view.dispatch({
          effects: EditorView.scrollIntoView(view.state.selection.main.head, { y: "end" }),
        });
      }, 0);
    }

    // Auto-grow changes the editor's height as the user types — the terminal
    // above must refit. Debounced: a paste can wrap many lines at once.
    let resizeTimer: number | undefined;
    let observer: ResizeObserver | undefined;
    if (typeof ResizeObserver !== "undefined") {
      let initial = true;
      observer = new ResizeObserver(() => {
        // The observe() call itself fires once — that's the open/close
        // resize the app already refits for.
        if (initial) {
          initial = false;
          return;
        }
        window.clearTimeout(resizeTimer);
        resizeTimer = window.setTimeout(() => cbs.current.onResize(), 150);
      });
      observer.observe(host);
    }

    return () => {
      window.clearTimeout(scrollTimer);
      window.clearTimeout(resizeTimer);
      observer?.disconnect();
      viewRef.current = null;
      view.destroy();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // External value changes (mention pick, attach, session switch, send-clear):
  // replace the document and park the cursor at the end.
  useEffect(() => {
    if (appliedThemeRef.current === resolvedTheme) return;
    appliedThemeRef.current = resolvedTheme;
    viewRef.current?.dispatch({
      effects: themeCompartment.current.reconfigure(dalaTheme(resolvedTheme)),
    });
  }, [resolvedTheme]);

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

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    view.dispatch({
      effects: sizingCompartment.current.reconfigure(
        EditorView.theme(composerSizing(fullscreen, coarsePointerNow())),
      ),
    });
  }, [fullscreen]);

  // User-initiated opens focus with the cursor at the END of the draft.
  useEffect(() => {
    const view = viewRef.current;
    if (!view || focusNonce === 0 || focusNonce === focusConsumed) return;
    onFocusConsumed(focusNonce);
    view.focus();
    const end = view.state.doc.length;
    view.dispatch({
      selection: { anchor: end },
      // A long draft must land showing its end, not its top.
      effects: EditorView.scrollIntoView(end, { y: "end" }),
    });
    // focusConsumed is a render-time snapshot on purpose (see Props).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusNonce]);

  return (
    <div
      ref={hostRef}
      id="composer-editor"
      // Height policy lives in composerSize.ts: bounded auto-grow normally,
      // fill-the-host in fullscreen (the host becomes a flex-1 child there).
      className={[
        "w-full overflow-hidden rounded-md border border-line bg-bg0 font-mono transition-colors focus-within:border-mint/60",
        fullscreen && "min-h-0 flex-1",
      ]
        .filter(Boolean)
        .join(" ")}
    />
  );
}
