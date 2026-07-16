import type { GitFile, Status } from "./gitPanel/types";

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

export type GitDecorationIndex = {
  entries: Map<string, GitDecoration>;
  ignored: Set<string>;
};

function trimTrailingSlash(path: string): string {
  return path.length > 1 ? path.replace(/\/+$/, "") : path;
}

function join(root: string, relative: string): string {
  const cleanRoot = trimTrailingSlash(root);
  const cleanRelative = relative.replace(/^\/+/, "");
  return cleanRoot === "/" ? `/${cleanRelative}` : `${cleanRoot}/${cleanRelative}`;
}

function parent(path: string): string | null {
  const clean = trimTrailingSlash(path);
  if (clean === "/") return null;
  const index = clean.lastIndexOf("/");
  if (index < 0) return null;
  return index === 0 ? "/" : clean.slice(0, index);
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
  const root = trimTrailingSlash(status.root);

  for (const path of status.ignored) {
    const absolute = join(root, path);
    ignored.add(absolute);
    entries.set(absolute, IGNORED_DECORATION);
  }

  for (const file of status.files) {
    const absolute = join(root, file.path);
    const decoration = fileDecoration(file);
    entries.set(absolute, decoration);

    let dir = parent(absolute);
    while (dir && (dir === root || dir.startsWith(`${root}/`))) {
      const existing = entries.get(dir);
      if (!existing || TONE_PRIORITY[decoration.tone] > TONE_PRIORITY[existing.tone]) {
        entries.set(dir, { ...decoration, label: "•" });
      }
      if (dir === root) break;
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
  const exact = decorations.entries.get(trimTrailingSlash(path));
  if (exact) return exact;

  let dir = parent(path);
  while (dir) {
    if (decorations.ignored.has(dir)) return IGNORED_DECORATION;
    dir = parent(dir);
  }
  return undefined;
}
