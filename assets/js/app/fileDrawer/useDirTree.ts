import { useCallback, useEffect, useRef, useState } from "react";
import { listDirectory } from "../../ash_rpc";
import type { ListDirectoryFields } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
import { useFileWatcher } from "../hooks/useFileWatcher";
import { routeChanged } from "./tree";
import type { Entry, Listing } from "./tree";

// "entries" as a leaf field returns the full entry maps; the generated
// selection type has no shape for arrays of typed maps, hence the cast.
const DIR_FIELDS = ["path", "parent", "entries"] as unknown as ListDirectoryFields;

/**
 * The directory tree's data layer: the root listing, loaded children,
 * expansion state, and the /files/watch socket keeping everything fresh
 * when terminal commands or agents touch the filesystem.
 */
export function useDirTree(
  path: string,
  onError: (message: string) => void,
  onExternalChange?: () => void,
) {
  const { t } = useI18n();
  // Held in a ref so an inline callback from the caller cannot change
  // fetchDir's identity — that would re-run the root-load effect on every
  // render (an unbounded refetch loop).
  const errorRef = useRef(onError);
  errorRef.current = onError;
  const [root, setRoot] = useState<Listing | null>(null);
  const [children, setChildren] = useState<Record<string, Entry[]>>({});
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [loadingDirs, setLoadingDirs] = useState<Set<string>>(new Set());

  // Remember each root's tree (expanded folders + loaded children) so switching
  // the drawer path away and back — chiefly switching session tabs, which
  // retargets the drawer at the new session's cwd — restores it instead of
  // collapsing everything to the root. Kept in a ref (survives the path-change
  // re-renders) on the single app-level FileDrawer; lost only when the drawer
  // itself unmounts.
  const cacheRef = useRef<
    Map<string, { root: Listing; children: Record<string, Entry[]>; expanded: Set<string> }>
  >(new Map());

  const fetchDir = useCallback(
    async (target: string): Promise<Listing | null> => {
      const result = await call<Listing>(listDirectory, {
        input: { path: target },
        fields: DIR_FIELDS,
      });
      if (result.ok) return result.data;
      errorRef.current(result.error || t("couldNotListDirectory"));
      return null;
    },
    [t],
  );

  const refreshDir = useCallback(
    async (dir: string) => {
      const listing = await fetchDir(dir);
      if (listing) setChildren((prev) => ({ ...prev, [dir]: listing.entries }));
    },
    [fetchDir],
  );

  // Keep each root's snapshot current so it can be restored later.
  useEffect(() => {
    if (root) cacheRef.current.set(root.path, { root, children, expanded });
  }, [root, children, expanded]);

  // (Re)load the tree root whenever the drawer path changes. If we've shown
  // this root before, restore its snapshot instantly (expanded folders intact)
  // and refresh the visible dirs in the background, so a session round-trip
  // doesn't re-collapse the tree; otherwise load it fresh.
  useEffect(() => {
    let stale = false;
    const cached = cacheRef.current.get(path);

    if (cached) {
      setRoot(cached.root);
      setChildren(cached.children);
      setExpanded(cached.expanded);
      // Refresh the restored (possibly stale) dirs silently — a folder deleted
      // while we were away must not pop an error toast on return.
      for (const dir of cached.expanded) {
        void call<Listing>(listDirectory, { input: { path: dir }, fields: DIR_FIELDS }).then(
          (r) => {
            if (!stale && r.ok) setChildren((prev) => ({ ...prev, [dir]: r.data.entries }));
          },
        );
      }
      return () => {
        stale = true;
      };
    }

    void fetchDir(path).then((listing) => {
      if (stale || !listing) return;
      setRoot(listing);
      setChildren({ [listing.path]: listing.entries });
      setExpanded(new Set([listing.path]));
    });
    return () => {
      stale = true;
    };
  }, [path, fetchDir]);

  // External changes (terminal commands, agents deleting/creating files)
  // don't announce themselves — a watch socket does: the server watches the
  // drawer root *recursively* (dala_holder watch; mtime polling as a last
  // resort) and pushes {"changed": dir} for any affected directory, however
  // deep. Each push routes to what is on screen: expanded dirs refresh,
  // loaded-but-collapsed dirs drop their stale cache, anything else
  // refreshes the nearest expanded ancestor. Silent; reconnects with
  // backoff, resyncing on reconnect (events during the gap are lost).
  const refreshSilent = useCallback(
    async (dir: string) => {
      const result = await call<Listing>(listDirectory, {
        input: { path: dir },
        fields: DIR_FIELDS,
      });
      if (result.ok) {
        setChildren((prev) => ({ ...prev, [dir]: result.data.entries }));
      }
    },
    [],
  );

  const expandedRef = useRef(expanded);
  expandedRef.current = expanded;
  const childrenRef = useRef(children);
  childrenRef.current = children;
  const externalChangeRef = useRef(onExternalChange);
  externalChangeRef.current = onExternalChange;

  const handleChanged = useCallback(
    (changed: readonly string[]) => {
      const refresh = new Set<string>();
      const invalidate = new Set<string>();
      for (const dir of changed) {
        const action = routeChanged(
          dir,
          expandedRef.current,
          new Set(Object.keys(childrenRef.current)),
        );
        if (action.kind === "refresh") refresh.add(action.dir);
        else if (action.kind === "invalidate") invalidate.add(action.dir);
      }
      for (const dir of refresh) void refreshSilent(dir);
      if (invalidate.size > 0) {
        setChildren((prev) => {
          const next = { ...prev };
          for (const dir of invalidate) delete next[dir];
          return next;
        });
      }
      externalChangeRef.current?.();
    },
    [refreshSilent],
  );

  const refreshExpanded = useCallback(() => {
    for (const dir of expandedRef.current) void refreshSilent(dir);
    externalChangeRef.current?.();
  }, [refreshSilent]);

  useFileWatcher(root?.path ?? null, [...expanded], handleChanged, refreshExpanded);

  // Manual refresh: refetch everything visible right now.
  const refreshAll = useCallback(() => {
    for (const dir of expandedRef.current) void refreshSilent(dir);
  }, [refreshSilent]);

  const toggleDir = async (dirPath: string) => {
    if (expanded.has(dirPath)) {
      setExpanded((prev) => {
        const next = new Set(prev);
        next.delete(dirPath);
        return next;
      });
      return;
    }

    if (!children[dirPath]) {
      setLoadingDirs((prev) => new Set(prev).add(dirPath));
      const listing = await fetchDir(dirPath);
      setLoadingDirs((prev) => {
        const next = new Set(prev);
        next.delete(dirPath);
        return next;
      });
      if (!listing) return;
      setChildren((prev) => ({ ...prev, [dirPath]: listing.entries }));
    }

    setExpanded((prev) => new Set(prev).add(dirPath));
  };

  /** Make a directory visible (e.g. so freshly uploaded files show up). */
  const expandDir = useCallback((dir: string) => {
    setExpanded((prev) => new Set(prev).add(dir));
  }, []);

  return {
    root,
    children,
    expanded,
    loadingDirs,
    refreshDir,
    refreshAll,
    toggleDir,
    expandDir,
  };
}
