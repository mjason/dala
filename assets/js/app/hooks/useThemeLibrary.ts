import { useCallback, useEffect, useRef, useState } from "react";
import type { Channel } from "phoenix";
import { listThemes } from "../../ash_rpc";
import { call } from "../rpc";
import {
  createSettingsChannel,
  onSettingsChannelMessages,
  unsubscribeSettingsChannel,
} from "../../ash_typed_channels";
import { getSocket } from "../socket";
import { applyTheme, loadThemeChoice } from "../theme";
import { relevantThemeOwner, type ThemeSummary } from "../themeLibrary";

/** The columns the picker/editor need from every library row. */
export const THEME_LIBRARY_FIELDS = [
  "id",
  "ownerId",
  "name",
  "base",
  "builtin",
  "tokens",
] as const;

/**
 * The custom-theme library: the caller's themes plus the global/built-in
 * presets (built-ins first, name-sorted by the server's `:list` action),
 * kept live across devices via the shared "settings" channel. Mirrors the
 * subscribe/refetch pattern of useSessions.
 *
 * The server's `:list` is already owner-scoped, so on a relevant event we
 * simply refetch and let the server be authoritative (a `theme_deleted` for
 * the selected theme is handled by theme.ts's own revalidation).
 */
export function useThemeLibrary(onError?: (message: string) => void) {
  const [themes, setThemes] = useState<ThemeSummary[]>([]);
  const themesRef = useRef<ThemeSummary[]>([]);
  useEffect(() => {
    themesRef.current = themes;
  }, [themes]);

  const onErrorRef = useRef(onError);
  onErrorRef.current = onError;

  // This client's own owner id, learned from the channel join reply (the actor
  // id when signed in, else the global sentinel). Lets a fresh device match its
  // first own theme event before any owned row exists in the library.
  const myOwnerRef = useRef<string | null>(null);

  const reload = useCallback(async () => {
    const result = await call<ThemeSummary[]>(listThemes, {
      fields: [...THEME_LIBRARY_FIELDS],
    });
    if (result.ok) setThemes(result.data);
    else onErrorRef.current?.(result.error);
  }, []);

  useEffect(() => {
    void reload();

    const socket = getSocket();
    const channel = createSettingsChannel(socket);
    const phxChannel = channel as unknown as Channel;
    // The payloads all carry `ownerId`; refetch only when the change touches a
    // library this client can see (its own owner or the global sentinel).
    const onEvent = (payload: { ownerId: string }) => {
      if (relevantThemeOwner(payload.ownerId, themesRef.current, myOwnerRef.current))
        void reload();
    };
    // A deleted theme that is the one we're currently showing must repaint, not
    // just drop from the list: revalidate through theme.ts, which fetches null
    // and falls the app back to system. Covers a delete on another device.
    const onDeleted = (payload: { ownerId: string; id: string }) => {
      const choice = loadThemeChoice();
      if (choice.setting === "custom" && choice.customId === payload.id) applyTheme();
      onEvent(payload);
    };
    const refs = onSettingsChannelMessages(channel, {
      theme_created: onEvent,
      theme_updated: onEvent,
      theme_deleted: onDeleted,
    });
    phxChannel.join().receive("ok", (resp: { owner_id?: string }) => {
      if (typeof resp?.owner_id === "string") myOwnerRef.current = resp.owner_id;
    });

    return () => {
      unsubscribeSettingsChannel(channel, refs);
      phxChannel.leave();
    };
  }, [reload]);

  return { themes, reload };
}
