/**
 * VS Code-style fuzzy filename matching: query characters must appear in
 * order; scoring prefers consecutive runs, matches at the start of a path
 * segment/word, and matches in the basename over the directory part.
 * Exact case-insensitive substrings rank above any scattered subsequence.
 */

export type FuzzyMatch = {
  score: number;
  /**
   * Indices for highlighting — code units into the NFC-normalized candidate
   * (`candidate.normalize("NFC")`), NOT into the raw candidate string:
   * composed accents and emoji make the two differ.
   */
  positions: number[];
};

const SEPARATORS = new Set(["/", "\\", "-", "_", ".", " "]);

// A scattered subsequence scores at most 13/char plus a 12-point span bonus,
// so this guarantees exact substrings sort above every scattered match.
const EXACT_BASE_BONUS = 1000;
const EXACT_PER_CHAR_BONUS = 20;

/** Per-character positional scoring shared by the exact and scattered paths. */
function scorePositions(c: string, lastSlash: number, positions: number[]): number {
  let score = 0;
  let previous = -2;
  for (const idx of positions) {
    score += 1;
    // Consecutive-run bonus grows with the run.
    if (idx === previous + 1) score += 4;
    // Segment/word starts are what people aim for.
    if (idx === 0 || SEPARATORS.has(c[idx - 1])) score += 6;
    // Prefer hits in the basename.
    if (idx > lastSlash) score += 2;
    previous = idx;
  }
  return score;
}

/** Scores the exact occurrence of `q` in `c` starting at `start`. */
function exactAt(c: string, lastSlash: number, q: string, start: number): FuzzyMatch {
  const positions = Array.from({ length: q.length }, (_, i) => start + i);
  let score = scorePositions(c, lastSlash, positions);
  score += EXACT_BASE_BONUS + EXACT_PER_CHAR_BONUS * q.length;
  // Maximally compact (span === query length), same as the formula below.
  score += 12;
  score -= Math.min(6, Math.floor(c.length / 40));
  return { score, positions };
}

function matchNormalized(q: string, c: string): FuzzyMatch | null {
  if (q.length === 0) return { score: 0, positions: [] };
  if (q.length > c.length) return null;

  const lastSlash = Math.max(c.lastIndexOf("/"), c.lastIndexOf("\\"));

  // Exact-substring fast path: a typed exact partial path must outrank any
  // scattered subsequence match.
  const exact = c.indexOf(q);
  if (exact !== -1) {
    let best = exactAt(c, lastSlash, q, exact);
    // The first occurrence may sit mid-directory while another lives in the
    // basename — basename hits are what users aim for, so probe there too
    // and keep the better-scored occurrence.
    if (exact <= lastSlash) {
      const inBasename = c.indexOf(q, lastSlash + 1);
      if (inBasename !== -1) {
        const alt = exactAt(c, lastSlash, q, inBasename);
        if (alt.score > best.score) best = alt;
      }
    }
    return best;
  }

  const positions: number[] = [];
  let ci = 0;

  for (let qi = 0; qi < q.length; qi++) {
    const idx = c.indexOf(q[qi], ci);
    if (idx === -1) return null;
    positions.push(idx);
    ci = idx + 1;
  }

  let score = scorePositions(c, lastSlash, positions);
  // Compactness: shorter overall span beats scattered matches.
  const span = positions[positions.length - 1] - positions[0] + 1;
  score += Math.max(0, 12 - (span - q.length));
  // Slightly favor shorter paths overall.
  score -= Math.min(6, Math.floor(c.length / 40));

  return { score, positions };
}

export function fuzzyMatch(query: string, candidate: string): FuzzyMatch | null {
  // NFC on both sides: macOS and some tools store filenames decomposed (NFD)
  // while keyboards produce NFC — without this they never match. Positions
  // therefore index the NFC form (see FuzzyMatch.positions). toLowerCase is
  // length-preserving for practical filename characters, so indices computed
  // on the lowercased string stay valid against the NFC original.
  const q = query.normalize("NFC").toLowerCase();
  const c = candidate.normalize("NFC").toLowerCase();

  const direct = matchNormalized(q, c);
  // A spaced query can target a space-less filename ("选币 研究" for
  // "选币研究demo.py"): also try the query with its whitespace removed and
  // keep the better result. Only QuickOpen can send such queries — the
  // composer's @-mention token stops at whitespace, so its queries never
  // contain spaces (the reverse case, space-less query vs spaced filename,
  // is already covered by the scattered-subsequence path).
  if (!/\s/.test(q)) return direct;
  const collapsed = matchNormalized(q.replace(/\s+/g, ""), c);
  if (!direct) return collapsed;
  if (!collapsed) return direct;
  return collapsed.score > direct.score ? collapsed : direct;
}

/**
 * Path-shaped queries come in as pasted absolute paths or `./`-relative
 * forms while candidates are root-relative: strip, in order, the list root
 * prefix, a leading `./`, and a leading `/`.
 */
function normalizeQuery(query: string, root?: string): string {
  let q = query.trim().normalize("NFC").replaceAll("\\", "/");
  if (root) {
    const r = root.normalize("NFC").replaceAll("\\", "/").replace(/\/+$/, "");
    if (r !== "") {
      // Case-sensitive first (the path as it exists on disk); the
      // case-insensitive retry covers macOS-style case-folding filesystems.
      if ((q + "/").startsWith(r + "/")) {
        q = q.slice(r.length);
      } else if ((q.toLowerCase() + "/").startsWith(r.toLowerCase() + "/")) {
        q = q.slice(r.length);
      }
    }
  }
  if (q.startsWith("./")) q = q.slice(2);
  if (q.startsWith("/")) q = q.slice(1);
  return q;
}

export type RankedFile = {
  /** The path exactly as the server sent it — use for opening/inserting. */
  path: string;
  /** NFC form of `path` — the string `positions` index into; render this. */
  display: string;
  positions: number[];
};

/**
 * Ranks `files` against `query`, returning at most `limit` best matches.
 * `root` is the absolute directory the candidate paths are relative to.
 *
 * `path` keeps the server's original bytes (NFD names on macOS volumes must
 * round-trip unchanged to open the file), while `display`/`positions` are in
 * NFC space for rendering — highlighting `path` directly would misalign on
 * composed characters.
 */
export function rankFiles(
  query: string,
  files: string[],
  limit = 100,
  root?: string,
): RankedFile[] {
  const q = normalizeQuery(query, root);

  if (q === "") {
    return files
      .slice(0, limit)
      .map((path) => ({ path, display: path.normalize("NFC"), positions: [] }));
  }

  const scored: { path: string; display: string; score: number; positions: number[] }[] = [];
  for (const path of files) {
    const display = path.normalize("NFC");
    const match = fuzzyMatch(q, display);
    if (match) scored.push({ path, display, score: match.score, positions: match.positions });
  }

  scored.sort((a, b) => b.score - a.score || a.path.length - b.path.length);
  return scored.slice(0, limit).map(({ path, display, positions }) => ({ path, display, positions }));
}
