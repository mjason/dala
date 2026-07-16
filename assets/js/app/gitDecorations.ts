import type { GitFile, Status } from "./gitPanel/types";

export type GitDecoration = {
  label: string;
  title: string;
  tone: "added" | "modified" | "deleted" | "renamed" | "untracked" | "conflict";
};

const TONE_PRIORITY: Record<GitDecoration["tone"], number> = {
  added: 1,
  renamed: 2,
  untracked: 2,
  modified: 3,
  deleted: 4,
  conflict: 5,
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
  const index = trimTrailingSlash(path).lastIndexOf("/");
  if (index < 0) return null;
  return index === 0 ? "/" : path.slice(0, index);
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
export function buildGitDecorations(status: Status | null): Map<string, GitDecoration> {
  const decorations = new Map<string, GitDecoration>();
  if (!status?.repo || !status.root) return decorations;
  const root = trimTrailingSlash(status.root);

  for (const file of status.files) {
    const absolute = join(root, file.path);
    const decoration = fileDecoration(file);
    decorations.set(absolute, decoration);

    let dir = parent(absolute);
    while (dir && (dir === root || dir.startsWith(`${root}/`))) {
      const existing = decorations.get(dir);
      if (!existing || TONE_PRIORITY[decoration.tone] > TONE_PRIORITY[existing.tone]) {
        decorations.set(dir, { ...decoration, label: "•" });
      }
      if (dir === root) break;
      dir = parent(dir);
    }
  }

  return decorations;
}
