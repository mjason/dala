import { describe, expect, it } from "vitest";
import { sizeRole } from "./sizeRole";

// Ownership has two axes: the DEVICE (permission — whose resizes the
// server applies, sticky) and the CLIENT (display — which same-device
// window currently drives the grid). The role derives purely from the
// server-reported {owner, owner_device} pair versus our own ids.
describe("sizeRole", () => {
  const me = { device: "my-device", client: "my-client" };
  const role = (msg: {
    owner?: string | null;
    owner_device?: string | null;
  } | null) => sizeRole(me.device, me.client, msg);

  it("drives when no device has ever owned the size (fresh session)", () => {
    expect(role({ owner: null, owner_device: null })).toBe("driver");
    expect(role({ owner: undefined, owner_device: undefined })).toBe("driver");
  });

  it("drives when this very connection is the live owner", () => {
    expect(role({ owner: "my-client", owner_device: "my-device" })).toBe("driver");
  });

  it("drives when our device owns the size with no live owner (reconnect)", () => {
    expect(role({ owner: null, owner_device: "my-device" })).toBe("driver");
  });

  it("hard-follows when another device owns the size (banner + explicit claim)", () => {
    expect(role({ owner: "their-client", owner_device: "other-device" })).toBe("follower");
    // ... even while the owning device is offline: the memory keeps it.
    expect(role({ owner: null, owner_device: "other-device" })).toBe("follower");
  });

  it("soft-follows a sibling window: same device, another live client", () => {
    // Two windows of one browser: the device axis says "allowed", the
    // client axis says another window drives the grid — render scaled,
    // no banner, no resize pushes (would thrash the shared PTY).
    expect(role({ owner: "other-window", owner_device: "my-device" })).toBe("soft-follower");
  });

  it("hard-follows an owner device even before knowing its own ids (defensive)", () => {
    expect(sizeRole(null, null, { owner: null, owner_device: "other-device" })).toBe("follower");
    expect(sizeRole(undefined, undefined, { owner: "x", owner_device: "other-device" })).toBe(
      "follower",
    );
  });

  it("drives before knowing its own client id on its own device (defensive)", () => {
    expect(sizeRole("my-device", null, { owner: "x", owner_device: "my-device" })).toBe("driver");
    expect(sizeRole("my-device", undefined, { owner: "x", owner_device: "my-device" })).toBe(
      "driver",
    );
  });

  it("drives against legacy servers that never report an owner device", () => {
    expect(role(null)).toBe("driver");
    expect(role({})).toBe("driver");
    expect(sizeRole(null, null, null)).toBe("driver");
  });
});
