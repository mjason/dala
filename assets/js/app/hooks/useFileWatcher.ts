import { useEffect, useRef } from "react";

type ChangeHandler = (directories: readonly string[]) => void;

function normalizedDirectories(directories: readonly string[]): string[] {
  return [...new Set(directories.filter(Boolean))].sort();
}

/**
 * Subscribes to the server's recursive file watcher for one root.
 *
 * Frames are merged per animation frame so a checkout/build storm reaches
 * consumers as one update. Changing the fallback polling directories updates
 * the live socket without restarting the native recursive watcher.
 */
export function useFileWatcher(
  root: string | null,
  directories: readonly string[],
  onChange: ChangeHandler,
  onReconnect?: () => void,
) {
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const onReconnectRef = useRef(onReconnect);
  onReconnectRef.current = onReconnect;

  const directoryKey = normalizedDirectories(directories).join("\0");
  const directoriesRef = useRef<string[]>([]);
  directoriesRef.current = directoryKey ? directoryKey.split("\0") : [];
  const socketRef = useRef<WebSocket | null>(null);

  const sendWatchList = (socket: WebSocket | null) => {
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ watch: directoriesRef.current, root }));
    }
  };

  useEffect(() => {
    sendWatchList(socketRef.current);
    // `root` reconnects in the connection effect below. This effect only
    // updates the fallback poll set when folders expand/collapse.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [directoryKey]);

  useEffect(() => {
    if (!root) {
      socketRef.current = null;
      return;
    }

    let disposed = false;
    let socket: WebSocket | null = null;
    let retry: number | undefined;
    let opened = false;
    let frame: number | undefined;
    let pending = new Set<string>();

    const flush = () => {
      frame = undefined;
      if (disposed || pending.size === 0) return;
      const changed = [...pending];
      pending = new Set();
      onChangeRef.current(changed);
    };

    const connect = () => {
      if (disposed) return;
      const proto = window.location.protocol === "https:" ? "wss" : "ws";
      const next = new WebSocket(`${proto}://${window.location.host}/files/watch`);
      socket = next;
      socketRef.current = next;

      next.onopen = () => {
        sendWatchList(next);
        if (opened) onReconnectRef.current?.();
        opened = true;
      };
      next.onmessage = (event) => {
        try {
          const body = JSON.parse(String(event.data)) as { changed?: string };
          if (!body.changed) return;
          pending.add(body.changed);
          if (frame == null) frame = requestAnimationFrame(flush);
        } catch {
          // Ignore malformed watcher frames.
        }
      };
      next.onclose = () => {
        if (socketRef.current === next) socketRef.current = null;
        if (!disposed) retry = window.setTimeout(connect, 3000);
      };
    };

    connect();

    return () => {
      disposed = true;
      window.clearTimeout(retry);
      if (frame != null) cancelAnimationFrame(frame);
      socket?.close();
      if (socketRef.current === socket) socketRef.current = null;
    };
    // Callbacks are refs; only a different recursive root needs a new socket.
  }, [root]);
}
