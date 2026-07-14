import { useCallback, useEffect, useRef, useState } from "react";
import { listDirectory } from "../../ash_rpc";
import type { ListDirectoryFields } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
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
export function useDirTree(path: string, onError: (message: string) => void) {
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

  // (Re)load the tree root whenever the drawer path changes.
  useEffect(() => {
    let stale = false;
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
  const rootPathRef = useRef<string | null>(null);
  rootPathRef.current = root?.path ?? null;
  const watchRef = useRef<WebSocket | null>(null);

  const sendWatchList = useCallback((socket: WebSocket | null) => {
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(
        JSON.stringify({ watch: [...expandedRef.current], root: rootPathRef.current }),
      );
    }
  }, []);

  useEffect(() => {
    let disposed = false;
    let socket: WebSocket | null = null;
    let retry: number | undefined;
    let reconnecting = false;

    // Change storms (builds, npm install, git checkout) arrive as many
    // {"changed"} frames in a burst. Collect them until the next animation
    // frame and route THEN, deduped by target — a hundred frames that all
    // route to one expanded ancestor cost one listDirectory, not a hundred.
    let storm: Set<string> | null = null;
    const flushStorm = () => {
      const changed = storm;
      storm = null;
      if (!changed || disposed) return;
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
    };

    const connect = () => {
      if (disposed) return;
      const proto = window.location.protocol === "https:" ? "wss" : "ws";
      const s = new WebSocket(`${proto}://${window.location.host}/files/watch`);
      socket = s;
      watchRef.current = s;
      s.onopen = () => {
        sendWatchList(s);
        if (reconnecting) {
          for (const dir of expandedRef.current) void refreshSilent(dir);
        }
        reconnecting = true;
      };
      s.onmessage = (event) => {
        try {
          const body = JSON.parse(String(event.data)) as { changed?: string };
          if (!body.changed) return;
          if (storm) {
            storm.add(body.changed);
            return;
          }
          storm = new Set([body.changed]);
          requestAnimationFrame(flushStorm);
        } catch {
          // ignore malformed frames
        }
      };
      s.onclose = () => {
        // Strict-mode double-mount (and reconnects) interleave sockets: the
        // doomed first socket's close event fires *after* the replacement is
        // registered — only clear the ref if it is still ours, or the live
        // socket becomes unreachable and watch-list updates silently stop.
        if (watchRef.current === s) watchRef.current = null;
        if (!disposed) retry = window.setTimeout(connect, 3000);
      };
    };
    connect();

    return () => {
      disposed = true;
      window.clearTimeout(retry);
      socket?.close();
    };
  }, [refreshSilent, sendWatchList]);

  // Keep the server's watch list (and root) in sync with the screen.
  useEffect(() => {
    sendWatchList(watchRef.current);
  }, [expanded, root, sendWatchList]);

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
