import type { MessageKey } from "../i18n";

export type Entry = {
  name: string;
  type: string;
  symlink: boolean;
  size: number;
  mtime: string | null;
};

export type Listing = {
  path: string;
  parent: string | null;
  entries: Entry[];
};

export type TreeRow =
  | { kind: "up"; path: string }
  | { kind: "dir" | "file"; path: string; entry: Entry; depth: number; parentDir: string }
  | { kind: "note"; id: string; text: string; depth: number };

export type SelectableRow = Exclude<TreeRow, { kind: "note" }>;

export type DeleteTarget = { path: string; isDir: boolean; parentDir: string };

export function join(dir: string, name: string): string {
  return `${dir === "/" ? "" : dir}/${name}`;
}

/** VS Code-style relative path from the drawer root to a target. */
export function relativePath(from: string, to: string): string {
  const f = from.split("/").filter(Boolean);
  const s = to.split("/").filter(Boolean);
  let i = 0;
  while (i < f.length && i < s.length && f[i] === s[i]) i++;
  const parts = [...Array(f.length - i).fill(".."), ...s.slice(i)];
  return parts.length ? parts.join("/") : ".";
}

export function crumbs(path: string): { label: string; path: string }[] {
  if (path === "/") return [{ label: "/", path: "/" }];
  const parts = path.split("/").filter(Boolean);
  const out = [{ label: "/", path: "/" }];
  let acc = "";
  for (const part of parts) {
    acc += "/" + part;
    out.push({ label: part, path: acc });
  }
  return out;
}

/** What the tree should do about a server-side change notification. */
export type ChangeAction =
  | { kind: "refresh"; dir: string }
  | { kind: "invalidate"; dir: string }
  | { kind: "none" };

/**
 * Routes a `{"changed": dir}` push (the watcher covers the whole tree
 * recursively, so `dir` may be anywhere under the root) to what is on
 * screen: an expanded dir refetches; a loaded-but-collapsed dir drops its
 * cached listing so re-expanding refetches instead of showing stale
 * entries; anything else refreshes the nearest expanded ancestor.
 */
export function routeChanged(
  dir: string,
  expanded: Set<string>,
  loaded: Set<string>,
): ChangeAction {
  if (expanded.has(dir)) return { kind: "refresh", dir };
  if (loaded.has(dir)) return { kind: "invalidate", dir };

  let cursor = dir;
  while (cursor !== "/" && cursor.includes("/")) {
    cursor = cursor.slice(0, cursor.lastIndexOf("/")) || "/";
    if (expanded.has(cursor)) return { kind: "refresh", dir: cursor };
  }
  return { kind: "none" };
}

type Translate = (key: MessageKey, params?: Record<string, string | number>) => string;

/**
 * The tree flattened to visible rows — one source of truth for both
 * rendering and keyboard navigation.
 */
export function buildTreeRows(
  root: Listing | null,
  children: Record<string, Entry[]>,
  expanded: Set<string>,
  showHidden: boolean,
  t: Translate,
): TreeRow[] {
  const out: TreeRow[] = [];
  if (root?.parent != null) out.push({ kind: "up", path: root.parent });

  const walk = (dirPath: string, depth: number) => {
    const all = children[dirPath];
    if (!all) return;

    const entries = all.filter((entry) => showHidden || !entry.name.startsWith("."));
    const hiddenCount = all.length - entries.length;

    for (const entry of entries) {
      const entryPath = join(dirPath, entry.name);
      if (entry.type === "directory") {
        out.push({ kind: "dir", path: entryPath, entry, depth, parentDir: dirPath });
        if (expanded.has(entryPath)) walk(entryPath, depth + 1);
      } else {
        out.push({ kind: "file", path: entryPath, entry, depth, parentDir: dirPath });
      }
    }

    if (hiddenCount > 0 && !showHidden) {
      out.push({
        kind: "note",
        id: dirPath + ":hidden",
        text: t("hiddenCount", { count: hiddenCount }),
        depth,
      });
    }
    if (all.length === 0) {
      out.push({ kind: "note", id: dirPath + ":empty", text: t("emptyDirectory"), depth });
    }
  };

  if (root) walk(root.path, 0);
  return out;
}
