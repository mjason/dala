import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { GLOBAL_THEME_OWNER } from "../themeLibrary";

// --- RPC: control what listThemes returns ---------------------------------
const listThemes = vi.fn();
vi.mock("../../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  listThemes: (...a: unknown[]) => listThemes(...a),
}));

// --- theme.ts: spy the apply-layer the hook now drives on a delete --------
const applyTheme = vi.fn();
let choice: { setting: string; customId: string | null } = { setting: "system", customId: null };
vi.mock("../theme", () => ({
  applyTheme: (...a: unknown[]) => applyTheme(...a),
  loadThemeChoice: () => choice,
}));

// --- Channel: capture handlers, and let join() resolve with an owner id ----
type EventPayload = { ownerId: string; id?: string };
type Handlers = {
  theme_created?: (p: EventPayload) => void;
  theme_updated?: (p: EventPayload) => void;
  theme_deleted?: (p: EventPayload) => void;
};
let handlers: Handlers = {};
let joinReply: { owner_id?: string } = {};
const leave = vi.fn();
const unsubscribe = vi.fn();
// join() returns a chainable Push whose "ok" callback fires with joinReply.
const receiveChain = { receive: () => receiveChain };
const join = vi.fn(() => ({
  receive: (status: string, cb: (resp: unknown) => void) => {
    if (status === "ok") cb(joinReply);
    return receiveChain;
  },
}));
const fakeChannel = { join, leave };
vi.mock("../socket", () => ({ getSocket: () => ({ channel: () => fakeChannel }) }));
vi.mock("../../ash_typed_channels", () => ({
  createSettingsChannel: () => fakeChannel,
  onSettingsChannelMessages: (_ch: unknown, h: Handlers) => {
    handlers = h;
    return {};
  },
  unsubscribeSettingsChannel: (...a: unknown[]) => unsubscribe(...a),
}));

import { useThemeLibrary } from "./useThemeLibrary";

const ok = (data: unknown) => ({ success: true, data });

beforeEach(() => {
  handlers = {};
  joinReply = {};
  choice = { setting: "system", customId: null };
  listThemes.mockReset();
  applyTheme.mockClear();
});

afterEach(() => vi.clearAllMocks());

/** Render the hook after its initial listThemes resolves to `library`. */
async function mountWith(library: { ownerId: string }[]) {
  listThemes.mockResolvedValue(ok(library));
  const view = renderHook(() => useThemeLibrary());
  await waitFor(() => expect(view.result.current.themes).toHaveLength(library.length));
  expect(listThemes).toHaveBeenCalledTimes(1);
  return view;
}

describe("useThemeLibrary channel sync", () => {
  it("refetches on a theme_created for the global/anonymous library", async () => {
    await mountWith([{ ownerId: GLOBAL_THEME_OWNER }]);
    handlers.theme_created?.({ ownerId: GLOBAL_THEME_OWNER });
    await waitFor(() => expect(listThemes).toHaveBeenCalledTimes(2));
  });

  it("refetches on a theme_created for an owner already in my library", async () => {
    await mountWith([{ ownerId: GLOBAL_THEME_OWNER }, { ownerId: "mine-1" }]);
    handlers.theme_created?.({ ownerId: "mine-1" });
    await waitFor(() => expect(listThemes).toHaveBeenCalledTimes(2));
  });

  it("ignores a theme_created from a different owner I cannot see", async () => {
    await mountWith([{ ownerId: GLOBAL_THEME_OWNER }]);
    handlers.theme_created?.({ ownerId: "stranger-9" });
    // Give any (erroneous) refetch a chance to fire, then assert it did not.
    await new Promise((r) => setTimeout(r, 20));
    expect(listThemes).toHaveBeenCalledTimes(1);
  });

  it("refetches for my FIRST own theme via the join-reply owner id (no owned row yet)", async () => {
    joinReply = { owner_id: "me-1" };
    await mountWith([{ ownerId: GLOBAL_THEME_OWNER }]);
    // A created event for my own owner — my library has no owned row yet, so
    // only the join-reply owner id can make this relevant.
    handlers.theme_created?.({ ownerId: "me-1" });
    await waitFor(() => expect(listThemes).toHaveBeenCalledTimes(2));
  });

  it("repaints via theme.ts when the ACTIVE custom theme is deleted (any device)", async () => {
    choice = { setting: "custom", customId: "A" };
    await mountWith([{ ownerId: GLOBAL_THEME_OWNER }, { ownerId: "mine-1" }]);
    handlers.theme_deleted?.({ ownerId: "mine-1", id: "A" });
    expect(applyTheme).toHaveBeenCalledTimes(1);
  });

  it("does not repaint when a NON-active theme is deleted", async () => {
    choice = { setting: "custom", customId: "A" };
    await mountWith([{ ownerId: GLOBAL_THEME_OWNER }, { ownerId: "mine-1" }]);
    handlers.theme_deleted?.({ ownerId: "mine-1", id: "B" });
    expect(applyTheme).not.toHaveBeenCalled();
  });

  it("joins on mount and unsubscribes/leaves on unmount", async () => {
    const view = await mountWith([{ ownerId: GLOBAL_THEME_OWNER }]);
    expect(join).toHaveBeenCalled();
    view.unmount();
    expect(unsubscribe).toHaveBeenCalled();
    expect(leave).toHaveBeenCalled();
  });
});
