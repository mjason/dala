/**
 * Builds minimal unified patches for one merge-view chunk, so single hunks
 * can be staged, unstaged or discarded (Fork-style) via `git apply`.
 *
 * The chunk is expressed in 1-based line ranges over the two full documents:
 * `[fromA, toA)` in the old text, `[fromB, toB)` in the new text — exactly
 * what @codemirror/merge's chunks map to. `reverse` swaps the roles, which
 * is how undo directions (unstage, discard) are applied.
 */

export type ChunkLines = {
  /** 1-based, half-open line range in the old document. */
  fromA: number;
  toA: number;
  /** 1-based, half-open line range in the new document. */
  fromB: number;
  toB: number;
};

const CONTEXT = 3;

function splitLines(text: string): string[] {
  const lines = text.split("\n");
  // A trailing newline produces one phantom empty element; drop it so line
  // counts match what git sees.
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

export function buildChunkPatch(
  filePath: string,
  oldText: string,
  newText: string,
  chunk: ChunkLines,
  opts: { reverse?: boolean } = {},
): string {
  const oldLines = splitLines(oldText);
  const newLines = splitLines(newText);

  // Shared context around the chunk (bounded by both documents).
  const beforeCount = Math.min(CONTEXT, chunk.fromA - 1, chunk.fromB - 1);
  const afterAvailableA = oldLines.length - (chunk.toA - 1);
  const afterAvailableB = newLines.length - (chunk.toB - 1);
  const afterCount = Math.min(CONTEXT, afterAvailableA, afterAvailableB);

  const context = (lines: string[], from: number, count: number) =>
    lines.slice(from - 1, from - 1 + count).map((line) => " " + line);

  const before = context(oldLines, chunk.fromA - beforeCount, beforeCount);
  const after = context(oldLines, chunk.toA, afterCount);

  const removed = oldLines.slice(chunk.fromA - 1, chunk.toA - 1).map((line) => "-" + line);
  const added = newLines.slice(chunk.fromB - 1, chunk.toB - 1).map((line) => "+" + line);

  let oldStart = chunk.fromA - beforeCount;
  let newStart = chunk.fromB - beforeCount;
  let oldCount = beforeCount + removed.length + afterCount;
  let newCount = beforeCount + added.length + afterCount;
  let bodyRemoved = removed;
  let bodyAdded = added;

  if (opts.reverse) {
    [oldStart, newStart] = [newStart, oldStart];
    [oldCount, newCount] = [newCount, oldCount];
    bodyRemoved = added.map((line) => "-" + line.slice(1));
    bodyAdded = removed.map((line) => "+" + line.slice(1));
  }

  // Empty ranges are printed with a 0 count and the line *before* the range.
  const position = (start: number, count: number) => (count === 0 ? start - 1 : start);

  const header =
    `@@ -${position(oldStart, oldCount)},${oldCount} ` +
    `+${position(newStart, newCount)},${newCount} @@`;

  return [
    `diff --git a/${filePath} b/${filePath}`,
    `--- a/${filePath}`,
    `+++ b/${filePath}`,
    header,
    ...before,
    ...bodyRemoved,
    ...bodyAdded,
    ...after,
    "",
  ].join("\n");
}
