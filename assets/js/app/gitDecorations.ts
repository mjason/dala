import type { GitFile, Status } from "./gitPanel/types";
import { dirnameHost, hostPathKey, joinHost } from "./hostPath";

export type GitDecoration = {
  label: string;
  title: string;
  tone: "added" | "modified" | "deleted" | "renamed" | "untracked" | "conflict" | "ignored";
};

const TONE_PRIORITY: Record<GitDecoration["tone"], number> = {
  ignored: 0,
  added: 1,
  renamed: 2,
  untracked: 2,
  modified: 3,
  deleted: 4,
  conflict: 5,
};

const IGNORED_DECORATION: GitDecoration = {
  label: "I",
  title: "Git ignored",
  tone: "ignored",
};

// The single-letter badge for each tone (VSCode-style). A folder shows the
// letter of its strongest descendant change instead of a bare dot, so the
// colour + letter read the same way a file's badge does.
const TONE_LETTER: Record<GitDecoration["tone"], string> = {
  ignored: "I",
  added: "A",
  renamed: "R",
  untracked: "U",
  modified: "M",
  deleted: "D",
  conflict: "!",
};

function folderSummary(tone: GitDecoration["tone"]): GitDecoration {
  return { label: TONE_LETTER[tone], title: `Contains ${tone} changes`, tone };
}

export type GitDecorationIndex = {
  entries: Map<string, GitDecoration>;
  ignored: Set<string>;
};

function parent(path: string): string | null {
  const result = dirnameHost(path);
  return hostPathKey(result) === hostPathKey(path) || result === "." ? null : result;
}

function fileDecoration(file: GitFile): GitDecoration {
  const status = file.status.padEnd(2, " ").slice(0, 2);
  const conflict = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].includes(status);
  const code = status === "??" ? "U" : status[1] !== " " ? status[1] : status[0];
  const tone: GitDecoration["tone"] = conflict
    ? "conflict"
    : status === "??"
      ? "untracked"
      : code === "D"
        ? "deleted"
        : code === "R" || code === "C"
          ? "renamed"
          : code === "A"
            ? "added"
            : "modified";

  return {
    label: conflict ? "!" : code || "M",
    title: `Git ${file.status}`,
    tone,
  };
}

/** Absolute file/folder decorations for a repository status snapshot. */
export function buildGitDecorations(status: Status | null): GitDecorationIndex {
  const entries = new Map<string, GitDecoration>();
  const ignored = new Set<string>();
  if (!status?.repo || !status.root) return { entries, ignored };
  const root = status.root.replace(/[\\/]+$/, "") || "/";
  const rootKey = hostPathKey(root);
  const rootPrefix = rootKey.endsWith("/") ? rootKey : `${rootKey}/`;

  for (const path of status.ignored) {
    const absolute = joinHost(root, path);
    const key = hostPathKey(absolute);
    ignored.add(key);
    entries.set(key, IGNORED_DECORATION);
  }

  for (const file of status.files) {
    const absolute = joinHost(root, file.path);
    const decoration = fileDecoration(file);
    entries.set(hostPathKey(absolute), decoration);

    const summary = folderSummary(decoration.tone);
    let dir = parent(absolute);
    while (dir && (hostPathKey(dir) === rootKey || hostPathKey(dir).startsWith(rootPrefix))) {
      const key = hostPathKey(dir);
      const existing = entries.get(key);
      if (!existing || TONE_PRIORITY[decoration.tone] > TONE_PRIORITY[existing.tone]) {
        entries.set(key, summary);
      }
      if (key === rootKey) break;
      dir = parent(dir);
    }
  }

  return { entries, ignored };
}

/** Exact Git state first, then inherit an ignored-directory hint. */
export function gitDecorationForPath(
  decorations: GitDecorationIndex,
  path: string,
): GitDecoration | undefined {
  const exact = decorations.entries.get(hostPathKey(path));
  if (exact) return exact;

  let dir = parent(path);
  while (dir) {
    if (decorations.ignored.has(hostPathKey(dir))) return IGNORED_DECORATION;
    dir = parent(dir);
  }
  return undefined;
}
