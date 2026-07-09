/**
 * Pure keyboard behaviors for the code editor, factored out of the React
 * component so they can be unit-tested without a DOM.
 */

const INDENT = "  ";

export type EditResult = {
  value: string;
  selectionStart: number;
  selectionEnd: number;
};

/** Tab / Shift+Tab: indent or outdent the selected lines (or insert indent). */
export function handleTab(
  value: string,
  start: number,
  end: number,
  shift: boolean,
): EditResult {
  const lineStart = value.lastIndexOf("\n", start - 1) + 1;

  // Multi-line selection, or Shift+Tab: operate line-by-line.
  if (shift || value.slice(start, end).includes("\n")) {
    const before = value.slice(0, lineStart);
    const block = value.slice(lineStart, end);
    const after = value.slice(end);

    if (shift) {
      let removedFirst = 0;
      let removedTotal = 0;
      const dedented = block
        .split("\n")
        .map((line, i) => {
          const strip = line.startsWith(INDENT) ? INDENT.length : line.startsWith(" ") ? 1 : 0;
          if (i === 0) removedFirst = strip;
          removedTotal += strip;
          return line.slice(strip);
        })
        .join("\n");

      return {
        value: before + dedented + after,
        selectionStart: Math.max(lineStart, start - removedFirst),
        selectionEnd: end - removedTotal,
      };
    }

    const lines = block.split("\n");
    const indented = lines.map((line) => INDENT + line).join("\n");
    return {
      value: before + indented + after,
      selectionStart: start + INDENT.length,
      selectionEnd: end + INDENT.length * lines.length,
    };
  }

  // Plain caret: insert indent at the caret.
  return {
    value: value.slice(0, start) + INDENT + value.slice(end),
    selectionStart: start + INDENT.length,
    selectionEnd: start + INDENT.length,
  };
}

/** Enter: keep the current line's leading whitespace on the new line. */
export function handleEnter(value: string, start: number, end: number): EditResult {
  const lineStart = value.lastIndexOf("\n", start - 1) + 1;
  const indent = value.slice(lineStart).match(/^[ \t]*/)?.[0] ?? "";
  const insert = "\n" + indent;

  return {
    value: value.slice(0, start) + insert + value.slice(end),
    selectionStart: start + insert.length,
    selectionEnd: start + insert.length,
  };
}

/** True for Cmd+S / Ctrl+S. */
export function isSaveShortcut(e: {
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
}): boolean {
  return (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s";
}
