/**
 * Pure helpers for the custom-theme LIBRARY (the picker in AppearanceSection
 * and its live channel sync). The DOM/React side lives in useThemeLibrary.ts;
 * the network apply-layer lives in theme.ts (Phase 1a).
 */
import type { EffectiveTheme } from "./theme";
import type { ThemeTokens } from "./themeTokens";

/**
 * The sentinel owner of every anonymous/global row — the six built-in presets
 * and (when authentication is off) every user's themes. Mirrors
 * `Dala.Settings.Theme.@global_id` on the server.
 */
export const GLOBAL_THEME_OWNER = "00000000-0000-0000-0000-000000000000";

/** One library row, as the picker consumes it (listThemes + channel payloads). */
export type ThemeSummary = {
  id: string;
  ownerId: string;
  name: string;
  base: EffectiveTheme;
  builtin: boolean;
  tokens: ThemeTokens;
};

/**
 * Whether a settings-channel theme event is relevant to MY library. The
 * "settings" topic is shared by every device, so a client only refreshes for
 * the global/built-in library, for its own owner id (`myOwnerId`, learned from
 * the channel join reply), or for an owner it can already see (its own rows) —
 * a theme from a different signed-in owner is ignored. Matching `myOwnerId` is
 * what lets a brand-new device (library still only the global presets, so no
 * owned row to match yet) recognise its FIRST own theme. Anonymous clients
 * share the global sentinel, so this accepts everything they can act on,
 * matching the server's `scope/2`.
 */
export function relevantThemeOwner(
  ownerId: string,
  library: { ownerId: string }[],
  myOwnerId?: string | null,
): boolean {
  return (
    ownerId === GLOBAL_THEME_OWNER ||
    (myOwnerId != null && ownerId === myOwnerId) ||
    library.some((row) => row.ownerId === ownerId)
  );
}
