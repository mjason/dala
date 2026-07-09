/**
 * VS Code-style fuzzy filename matching: query characters must appear in
 * order; scoring prefers consecutive runs, matches at the start of a path
 * segment/word, and matches in the basename over the directory part.
 */

export type FuzzyMatch = {
  score: number;
  /** Indices into the candidate string, for highlighting. */
  positions: number[];
};

const SEPARATORS = new Set(["/", "-", "_", ".", " "]);

export function fuzzyMatch(query: string, candidate: string): FuzzyMatch | null {
  if (query.length === 0) return { score: 0, positions: [] };
  if (query.length > candidate.length) return null;

  const q = query.toLowerCase();
  const c = candidate.toLowerCase();
  const lastSlash = candidate.lastIndexOf("/");

  const positions: number[] = [];
  let score = 0;
  let ci = 0;
  let previous = -2;

  for (let qi = 0; qi < q.length; qi++) {
    const idx = c.indexOf(q[qi], ci);
    if (idx === -1) return null;

    positions.push(idx);
    score += 1;
    // Consecutive-run bonus grows with the run.
    if (idx === previous + 1) score += 4;
    // Segment/word starts are what people aim for.
    if (idx === 0 || SEPARATORS.has(c[idx - 1])) score += 6;
    // Prefer hits in the basename.
    if (idx > lastSlash) score += 2;

    previous = idx;
    ci = idx + 1;
  }

  // Compactness: shorter overall span beats scattered matches.
  const span = positions[positions.length - 1] - positions[0] + 1;
  score += Math.max(0, 12 - (span - query.length));
  // Slightly favor shorter paths overall.
  score -= Math.min(6, Math.floor(candidate.length / 40));

  return { score, positions };
}

export type RankedFile = { path: string; positions: number[] };

/** Ranks `files` against `query`, returning at most `limit` best matches. */
export function rankFiles(query: string, files: string[], limit = 100): RankedFile[] {
  const trimmed = query.trim();

  if (trimmed === "") {
    return files.slice(0, limit).map((path) => ({ path, positions: [] }));
  }

  const scored: { path: string; score: number; positions: number[] }[] = [];
  for (const path of files) {
    const match = fuzzyMatch(trimmed, path);
    if (match) scored.push({ path, score: match.score, positions: match.positions });
  }

  scored.sort((a, b) => b.score - a.score || a.path.length - b.path.length);
  return scored.slice(0, limit).map(({ path, positions }) => ({ path, positions }));
}
