import { Socket } from "phoenix";
import { socketToken } from "./meta";

let socket: Socket | null = null;

export function getSocket(): Socket {
  if (!socket) {
    socket = new Socket("/socket", {
      params: socketToken ? { token: socketToken } : {},
    });
    socket.connect();
  }
  return socket;
}
