import { Socket } from "phoenix";
import { socketToken } from "./meta";

let socket: Socket | null = null;

// Counts completed socket opens. Registered at creation time — before any
// subscriber — so an onReconnect handler observing the same open event
// always sees the incremented value.
let opens = 0;

export function getSocket(): Socket {
  if (!socket) {
    socket = new Socket("/socket", {
      params: socketToken ? { token: socketToken } : {},
    });
    socket.onOpen(() => {
      opens += 1;
    });
    socket.connect();
  }
  return socket;
}

/**
 * Fires on every socket open EXCEPT the very first — i.e. only on
 * reconnects (server restart, network blip). Returns the unsubscribe.
 */
export function onReconnect(callback: () => void): () => void {
  const s = getSocket();
  const ref = s.onOpen(() => {
    if (opens > 1) callback();
  });
  return () => s.off([ref]);
}
