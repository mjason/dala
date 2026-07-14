import type { MessageKey } from "./i18n";

export type KeyGuideRow = {
  /** Combos pressed in sequence, e.g. ["Ctrl+O", "Ctrl+O"] or ["Ctrl+X", "B"]. */
  keys: string[];
  /** i18n key of the row's description. */
  descKey: MessageKey;
};

export type KeyGuideGroup = {
  /** Product name of the TUI app, rendered as-is (never translated). */
  app: string;
  rows: KeyGuideRow[];
};

/**
 * Key tricks that belong to the apps running INSIDE the terminal (claude
 * code, zellij, opencode, …) — dala's own rebindable shortcuts live in
 * keybindings.ts. Rendered in Settings → Shortcuts below the dala list;
 * add a row here and a matching description key in i18n/locales.ts.
 */
export const KEY_GUIDE: KeyGuideGroup[] = [
  {
    app: "claude code",
    rows: [
      { keys: ["Ctrl+O", "Ctrl+O"], descKey: "keyGuideClaudeReflow" },
      { keys: ["Shift+Tab"], descKey: "keyGuideClaudePermissions" },
    ],
  },
  {
    app: "zellij",
    rows: [
      { keys: ["Ctrl+G"], descKey: "keyGuideZellijLock" },
      { keys: ["Ctrl+S"], descKey: "keyGuideZellijScroll" },
    ],
  },
  {
    app: "opencode",
    rows: [{ keys: ["Ctrl+X", "B"], descKey: "keyGuideOpencodeSidebar" }],
  },
];
