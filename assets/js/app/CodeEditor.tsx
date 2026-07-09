import React, { useLayoutEffect, useMemo, useRef } from "react";
import { handleEnter, handleTab, isSaveShortcut } from "./editorKeys";

type Props = {
  value: string;
  onChange: (value: string) => void;
  onSave: () => void;
  wrap: boolean;
};

/**
 * Lightweight code editor: a monospace textarea with a scroll-synced line
 * number gutter, indent-aware Tab/Enter, and Cmd/Ctrl+S to save.
 */
export default function CodeEditor({ value, onChange, onSave, wrap }: Props) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const gutterRef = useRef<HTMLDivElement>(null);

  const lineCount = useMemo(() => Math.max(1, value.split("\n").length), [value]);

  // Keep the gutter aligned with the textarea's scroll position.
  useLayoutEffect(() => {
    const textarea = textareaRef.current;
    const gutter = gutterRef.current;
    if (!textarea || !gutter) return;

    const sync = () => {
      gutter.scrollTop = textarea.scrollTop;
    };
    textarea.addEventListener("scroll", sync);
    return () => textarea.removeEventListener("scroll", sync);
  }, []);

  const apply = (next: { value: string; selectionStart: number; selectionEnd: number }) => {
    onChange(next.value);
    // Restore the caret/selection after React re-renders the new value.
    requestAnimationFrame(() => {
      const textarea = textareaRef.current;
      if (textarea) {
        textarea.selectionStart = next.selectionStart;
        textarea.selectionEnd = next.selectionEnd;
      }
    });
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (isSaveShortcut(e)) {
      e.preventDefault();
      onSave();
      return;
    }

    const textarea = e.currentTarget;
    const { selectionStart, selectionEnd } = textarea;

    if (e.key === "Tab") {
      e.preventDefault();
      apply(handleTab(value, selectionStart, selectionEnd, e.shiftKey));
    } else if (e.key === "Enter") {
      e.preventDefault();
      apply(handleEnter(value, selectionStart, selectionEnd));
    }
  };

  return (
    <div className="flex min-h-0 flex-1 overflow-hidden bg-bg0">
      <div
        ref={gutterRef}
        aria-hidden
        className="shrink-0 select-none overflow-hidden border-r border-line bg-bg1/40 py-3 pl-3 pr-2 text-right font-mono text-[13px] leading-5 text-fg-muted/50"
      >
        {Array.from({ length: lineCount }, (_, i) => (
          <div key={i}>{i + 1}</div>
        ))}
      </div>
      <textarea
        id="code-editor"
        ref={textareaRef}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={onKeyDown}
        spellCheck={false}
        autoCapitalize="off"
        autoCorrect="off"
        wrap={wrap ? "soft" : "off"}
        className={`min-h-0 flex-1 resize-none bg-transparent px-3 py-3 font-mono text-[13px] leading-5 text-fg outline-none ${
          wrap ? "whitespace-pre-wrap [overflow-wrap:anywhere]" : "whitespace-pre"
        }`}
      />
    </div>
  );
}
