/** Structured model of a unified diff (git diff / git show output). */

export type DiffLineKind = "add" | "del" | "ctx";

export type DiffLine = {
  kind: DiffLineKind;
  text: string;
  oldNo: number | null;
  newNo: number | null;
};

export type DiffHunk = {
  header: string;
  lines: DiffLine[];
};

export type DiffFile = {
  oldPath: string;
  newPath: string;
  binary: boolean;
  additions: number;
  deletions: number;
  hunks: DiffHunk[];
};

export type ParsedDiff = {
  /** Anything before the first `diff --git` (commit message, stats, …). */
  preamble: string;
  files: DiffFile[];
};

const HUNK_RE = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/;

function stripPrefix(path: string): string {
  return path.replace(/^[ab]\//, "");
}

/**
 * git C-quotes paths with non-ASCII bytes in patch headers
 * (`"a/\346\226\207.txt"`): strip the quotes and decode the octal escapes
 * back into UTF-8 so the path matches what the filesystem/index use.
 */
export function unquoteGitPath(raw: string): string {
  let path = raw;
  if (path.startsWith('"') && path.endsWith('"')) path = path.slice(1, -1);
  if (!path.includes("\\")) return path;

  const bytes: number[] = [];
  for (let i = 0; i < path.length; i++) {
    if (path[i] !== "\\") {
      bytes.push(path.charCodeAt(i));
      continue;
    }
    const next = path[i + 1] ?? "";
    if (next >= "0" && next <= "7") {
      bytes.push(parseInt(path.slice(i + 1, i + 4), 8));
      i += 3;
    } else {
      const escapes: Record<string, string> = { n: "\n", t: "\t", r: "\r", '"': '"', "\\": "\\" };
      bytes.push((escapes[next] ?? next).charCodeAt(0));
      i += 1;
    }
  }
  return new TextDecoder().decode(new Uint8Array(bytes));
}

export function parseDiff(text: string): ParsedDiff {
  const lines = text.split("\n");
  const files: DiffFile[] = [];
  const preambleLines: string[] = [];

  let file: DiffFile | null = null;
  let hunk: DiffHunk | null = null;
  let oldNo = 0;
  let newNo = 0;

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      // "diff --git a/path b/path"
      const m = line.match(/^diff --git (?:"?a\/([^"]+)"?) (?:"?b\/([^"]+)"?)$/);
      file = {
        oldPath: m ? unquoteGitPath(m[1]) : "",
        newPath: m ? unquoteGitPath(m[2]) : "",
        binary: false,
        additions: 0,
        deletions: 0,
        hunks: [],
      };
      files.push(file);
      hunk = null;
      continue;
    }

    if (!file) {
      preambleLines.push(line);
      continue;
    }

    const hunkMatch = line.match(HUNK_RE);
    if (hunkMatch) {
      oldNo = parseInt(hunkMatch[1], 10);
      newNo = parseInt(hunkMatch[2], 10);
      hunk = { header: line, lines: [] };
      file.hunks.push(hunk);
      continue;
    }

    if (line.startsWith("Binary files ") || line === "GIT binary patch") {
      file.binary = true;
      continue;
    }

    // metadata between the file header and the first hunk
    if (!hunk) {
      const renamed = line.match(/^rename (from|to) (.+)$/);
      if (renamed) {
        if (renamed[1] === "from") file.oldPath = unquoteGitPath(renamed[2]);
        else file.newPath = unquoteGitPath(renamed[2]);
      }
      const plusPath = line.match(/^\+\+\+ "?b\/(.+?)"?$/);
      if (plusPath) file.newPath = unquoteGitPath(stripPrefix(plusPath[1]));
      const minusPath = line.match(/^--- "?a\/(.+?)"?$/);
      if (minusPath) file.oldPath = unquoteGitPath(stripPrefix(minusPath[1]));
      continue;
    }

    if (line.startsWith("+")) {
      hunk.lines.push({ kind: "add", text: line.slice(1), oldNo: null, newNo: newNo++ });
      file.additions++;
    } else if (line.startsWith("-")) {
      hunk.lines.push({ kind: "del", text: line.slice(1), oldNo: oldNo++, newNo: null });
      file.deletions++;
    } else if (line.startsWith("\\")) {
      // "\ No newline at end of file" — attach nothing
    } else {
      hunk.lines.push({ kind: "ctx", text: line.slice(1), oldNo: oldNo++, newNo: newNo++ });
    }
  }

  return { preamble: preambleLines.join("\n").trim(), files };
}

export type SplitRow = {
  left: DiffLine | null;
  right: DiffLine | null;
};

/** Pairs hunk lines into side-by-side rows: deletions left, additions right. */
export function toSplitRows(hunk: DiffHunk): SplitRow[] {
  const rows: SplitRow[] = [];
  let pendingDel: DiffLine[] = [];
  let pendingAdd: DiffLine[] = [];

  const flush = () => {
    const max = Math.max(pendingDel.length, pendingAdd.length);
    for (let i = 0; i < max; i++) {
      rows.push({ left: pendingDel[i] ?? null, right: pendingAdd[i] ?? null });
    }
    pendingDel = [];
    pendingAdd = [];
  };

  for (const line of hunk.lines) {
    if (line.kind === "del") {
      pendingDel.push(line);
    } else if (line.kind === "add") {
      pendingAdd.push(line);
    } else {
      flush();
      rows.push({ left: line, right: line });
    }
  }
  flush();

  return rows;
}
