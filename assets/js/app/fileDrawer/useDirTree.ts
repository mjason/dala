import { useCallback, useEffect, useRef, useState } from "react";
import { listDirectory } from "../../ash_rpc";
import type { ListDirectoryFields } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
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
      onError(result.error || t("couldNotListDirectory"));
      return null;
    },
    [onError, t],
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
  // don't announce themselves — a watch socket does: the server runs
  // inotifywait (or mtime polling) on the expanded directories and pushes
  // {"changed": dir}. Silent refresh; reconnects with backoff.
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
  const watchRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    let disposed = false;
    let socket: WebSocket | null = null;
    let retry: number | undefined;

    const connect = () => {
      if (disposed) return;
      const proto = window.location.protocol === "https:" ? "wss" : "ws";
      socket = new WebSocket(`${proto}://${window.location.host}/files/watch`);
      watchRef.current = socket;
      socket.onopen = () => {
        socket?.send(JSON.stringify({ watch: [...expandedRef.current] }));
      };
      socket.onmessage = (event) => {
        try {
          const body = JSON.parse(String(event.data)) as { changed?: string };
          if (body.changed) void refreshSilent(body.changed);
        } catch {
          // ignore malformed frames
        }
      };
      socket.onclose = () => {
        watchRef.current = null;
        if (!disposed) retry = window.setTimeout(connect, 3000);
      };
    };
    connect();

    return () => {
      disposed = true;
      window.clearTimeout(retry);
      socket?.close();
    };
  }, [refreshSilent]);

  // Keep the server's watch list in sync with what is expanded on screen.
  useEffect(() => {
    const socket = watchRef.current;
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ watch: [...expanded] }));
    }
  }, [expanded]);

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
