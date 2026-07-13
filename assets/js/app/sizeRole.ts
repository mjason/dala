// PTY size ownership, client side (server side: Dala.Terminal.Server).
//
// Ownership is DEVICE-sticky: a session remembers the one DEVICE whose
// `resize` reaches the PTY (persisted server-side), and every other client
// is a follower — it renders the grid at the owner's size and CSS-scales it
// down to fit its own screen. The role is decided purely from what the
// server says (join reply / `size_owner` broadcasts) compared against this
// browser's stable device id (deviceId.ts) AND this connection's client id:
//
// - Another DEVICE owns the size (live or merely remembered): hard
//   follower — scaled render plus the takeover banner; only the banner's
//   explicit claim transfers ownership.
// - OUR device owns it but ANOTHER connection of this device (a second
//   window/tab) is the live owner: soft follower — scaled render, no
//   banner, no resize pushes. Two same-device windows would otherwise
//   thrash the PTY (each fit-push flips ownership and rewraps the grid);
//   the window the user actually cares about retakes silently via the
//   explicit refit button (a plain resize — the device memory is ours).
// - Otherwise (unadopted session, our own live ownership, or a legacy
//   server that reports nothing): driver — fit to this screen and push
//   resizes.

export type SizeOwnerMessage = {
  /** client_id of the live owning channel, or null when nobody is
   * connected as the owner. Same-device windows tell each other apart by
   * it (the device axis alone cannot). */
  owner?: string | null;
  /** Stable device id that owns the size (live or remembered), or null
   * when no device ever adopted the session. */
  owner_device?: string | null;
  rows?: number;
  cols?: number;
};

export type SizeRole = "driver" | "soft-follower" | "follower";

/**
 * This client's size role for the server-reported ownership. Pure: same
 * inputs, same role — the device id is the PERMISSION axis (whose resizes
 * the server applies), the client id is the DISPLAY axis (which same-device
 * window currently drives the grid).
 */
export function sizeRole(
  myDeviceId: string | null | undefined,
  myClientId: string | null | undefined,
  msg: Pick<SizeOwnerMessage, "owner" | "owner_device"> | null | undefined,
): SizeRole {
  const ownerDevice = msg?.owner_device;
  // Never adopted, or a legacy server that doesn't report ownership: drive
  // our own size (the legacy per-connection behavior).
  if (ownerDevice == null) return "driver";
  if (ownerDevice !== myDeviceId) return "follower";
  // Our device owns the size. A live owner that isn't THIS connection is a
  // sibling window on the same device: follow its size silently. Not
  // knowing our own client id yet (defensive) counts as driving — closest
  // to the legacy model.
  const owner = msg?.owner;
  if (owner != null && myClientId != null && owner !== myClientId) {
    return "soft-follower";
  }
  return "driver";
}
