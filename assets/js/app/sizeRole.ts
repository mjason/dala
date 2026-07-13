// PTY size ownership, client side (server side: Dala.Terminal.Server).
//
// A session has at most ONE size owner: only its `resize` reaches the PTY.
// Everyone else is a follower — it renders the grid at the owner's size and
// CSS-scales it down to fit its own screen. The role is decided purely from
// what the server says (join reply / `size_owner` broadcasts), never from
// device heuristics: a phone opening a session alone claims ownership with
// its first resize and gets a native narrow PTY.

export type SizeOwnerMessage = {
  /** client_id of the owning channel, or null when ownership is free. */
  owner?: string | null;
  rows?: number;
  cols?: number;
};

/**
 * True when ANOTHER client owns the PTY size, i.e. this client must render
 * at the owner's size and scale to fit. Free ownership (null/undefined) or
 * owning it ourselves means we drive our own size — that is also the legacy
 * behavior against servers that don't report ownership at all.
 */
export function isSizeFollower(
  myClientId: string | null | undefined,
  ownerId: string | null | undefined,
): boolean {
  if (ownerId == null) return false;
  return ownerId !== myClientId;
}
