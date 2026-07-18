import { isMac } from "./shortcuts";

/**
 * Central keybinding registry: every shortcut in the app is declared here,
 * customized in Settings → Shortcuts, stored per browser and broadcast live
 * via a window event. Combo grammar: "+"-joined lowercase tokens —
 * modifiers `mod` (⌘ on Mac, Ctrl elsewhere — matches either, like the
 * hardcoded shortcuts always did), `ctrl`, `alt`, `shift`, then one key
 * (letter, "enter", "`", or a bare function key like "f2").
 */

export type BindingScope = "global" | "composer";

export type BindingSpec = {
  id: string;
  /** i18n key for the settings row label. */
  labelKey: string;
  default: string;
  scope: BindingScope;
  /** Mirrored into the desktop client's application menu. */
  clientMenu?: boolean;
};

export const BINDINGS: BindingSpec[] = [
  { id: "composer", labelKey: "kbComposer", default: "mod+shift+k", scope: "global", clientMenu: true },
  { id: "voice", labelKey: "speechStart", default: "mod+shift+m", scope: "global", clientMenu: true },
  { id: "quickShell", labelKey: "kbQuickShell", default: "ctrl+shift+`", scope: "global", clientMenu: true },
  { id: "focusTerminal", labelKey: "kbFocusTerminal", default: "ctrl+`", scope: "global" },
  { id: "quickOpen", labelKey: "quickOpenTitle", default: "mod+p", scope: "global" },
  { id: "sidebar", labelKey: "kbSidebar", default: "mod+b", scope: "global" },
  { id: "drawer", labelKey: "kbDrawer", default: "mod+shift+e", scope: "global" },
  { id: "git", labelKey: "kbGit", default: "mod+shift+g", scope: "global" },
  // ⌥⌘R / Ctrl+Alt+R — "R" for rename, and Alt keeps it clear of the browser
  // (mod+shift+r IS hard-reload). F2 would be the desktop convention, but on
  // a Mac it costs an fn chord, so it is not the default. Claimed even while
  // the terminal has focus (the handler stops propagation); rebindable.
  { id: "renameSession", labelKey: "kbRenameSession", default: "mod+alt+r", scope: "global" },
  { id: "refit", labelKey: "refitWidth", default: "mod+shift+f", scope: "global" },
  { id: "resetTerminal", labelKey: "resetTerminal", default: "mod+shift+x", scope: "global" },
  { id: "composerSend", labelKey: "inputBarSend", default: "shift+enter", scope: "composer" },
  { id: "composerMention", labelKey: "composerMention", default: "mod+shift+a", scope: "composer" },
  { id: "composerAttach", labelKey: "composerAttach", default: "mod+shift+u", scope: "composer" },
  { id: "composerStash", labelKey: "stashCurrentInput", default: "mod+shift+s", scope: "composer" },
];

const KEY = "dala:keybindings";
const EVENT = "dala:keybindings";

export function loadBindings(): Record<string, string> {
  let stored: Record<string, string> = {};
  try {
    stored = JSON.parse(localStorage.getItem(KEY) ?? "{}") as Record<string, string>;
  } catch {
    // corrupted storage — fall back to defaults
  }
  const map: Record<string, string> = {};
  for (const spec of BINDINGS) {
    const raw = stored[spec.id];
    map[spec.id] = typeof raw === "string" && raw ? raw : spec.default;
  }
  return map;
}

export function saveBinding(id: string, combo: string | null): Record<string, string> {
  let stored: Record<string, string> = {};
  try {
    stored = JSON.parse(localStorage.getItem(KEY) ?? "{}") as Record<string, string>;
  } catch {
    // start fresh
  }
  if (combo) stored[id] = combo;
  else delete stored[id];
  try {
    localStorage.setItem(KEY, JSON.stringify(stored));
  } catch {
    // storage unavailable — live update still happens
  }
  const map = loadBindings();
  window.dispatchEvent(new CustomEvent(EVENT, { detail: map }));
  return map;
}

export function resetBindings(): Record<string, string> {
  try {
    localStorage.removeItem(KEY);
  } catch {
    // ignore
  }
  const map = loadBindings();
  window.dispatchEvent(new CustomEvent(EVENT, { detail: map }));
  return map;
}

export function onBindingsChange(callback: (map: Record<string, string>) => void): () => void {
  const handler = (e: Event) => callback((e as CustomEvent<Record<string, string>>).detail);
  window.addEventListener(EVENT, handler);
  return () => window.removeEventListener(EVENT, handler);
}

// ------------------------------------------------------------------ match

type Parsed = {
  mod: boolean;
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  key: string;
};

export function parseCombo(combo: string): Parsed {
  const tokens = combo.toLowerCase().split("+");
  const key = tokens[tokens.length - 1];
  return {
    mod: tokens.includes("mod"),
    ctrl: tokens.includes("ctrl"),
    alt: tokens.includes("alt"),
    shift: tokens.includes("shift"),
    key,
  };
}

function eventKey(e: KeyboardEvent): string {
  if (e.code === "Backquote") return "`";
  // macOS composes Option+letter into a symbol (⌥R → "®"), so e.key is
  // useless for Alt combos. Fall back to the PHYSICAL key ("KeyR" → "r",
  // "Digit2" → "2") whenever Alt is held — layout-independent for the
  // letters/digits we bind.
  if (e.altKey) {
    const code = e.code;
    if (/^Key[A-Z]$/.test(code)) return code.slice(3).toLowerCase();
    if (/^Digit\d$/.test(code)) return code.slice(5);
  }
  const key = e.key.toLowerCase();
  return key === " " ? "space" : key;
}

/** Does this keyboard event match the combo? */
export function matchCombo(e: KeyboardEvent, combo: string): boolean {
  const want = parseCombo(combo);
  // "mod" accepts Ctrl OR Cmd (the app's historical behavior); explicit
  // "ctrl" requires the Control key itself.
  const modHeld = e.ctrlKey || e.metaKey;
  if (want.mod && !modHeld) return false;
  if (want.ctrl && !e.ctrlKey) return false;
  if (!want.mod && !want.ctrl && (e.ctrlKey || e.metaKey)) return false;
  if (want.alt !== e.altKey) return false;
  if (want.shift !== e.shiftKey) return false;
  return eventKey(e) === want.key;
}

/** Record a combo from a keydown event; null when it's only modifiers. */
export function comboFromEvent(e: KeyboardEvent): string | null {
  if (["Control", "Meta", "Alt", "Shift"].includes(e.key)) return null;
  const tokens: string[] = [];
  if ((isMac && e.metaKey) || (!isMac && e.ctrlKey)) tokens.push("mod");
  else if (e.ctrlKey) tokens.push("ctrl");
  else if (e.metaKey) tokens.push("meta");
  if (e.altKey) tokens.push("alt");
  if (e.shiftKey) tokens.push("shift");
  tokens.push(eventKey(e));
  return tokens.join("+");
}

// ----------------------------------------------------------------- display

const MAC_KEYS: Record<string, string> = { enter: "⏎", escape: "⎋", backspace: "⌫" };

/** F1–F24: the function keys browsers report and Electron accepts. */
function functionKey(key: string): boolean {
  return /^f([1-9]|1\d|2[0-4])$/.test(key);
}

/** Function keys ("f2") render as "F2"; other named keys keep their spelling. */
function displayKey(key: string): string {
  if (key.length === 1) return key.toUpperCase();
  if (functionKey(key)) return key.toUpperCase();
  return key;
}

/** Human-readable combo: "⇧⌘K" on Mac, "Ctrl+Shift+K" elsewhere. */
export function formatCombo(combo: string): string {
  const parsed = parseCombo(combo);
  const key = displayKey(parsed.key);
  if (isMac) {
    return [
      parsed.ctrl ? "⌃" : "",
      parsed.alt ? "⌥" : "",
      parsed.shift ? "⇧" : "",
      parsed.mod ? "⌘" : "",
      MAC_KEYS[parsed.key] ?? key,
    ].join("");
  }
  return [
    parsed.mod || parsed.ctrl ? "Ctrl" : "",
    parsed.alt ? "Alt" : "",
    parsed.shift ? "Shift" : "",
    key === "enter" ? "Enter" : key,
  ]
    .filter(Boolean)
    .join("+");
}

/** CodeMirror keymap key ("Shift-Enter") for a combo. */
export function comboToCodeMirror(combo: string): string {
  const parsed = parseCombo(combo);
  const key =
    parsed.key === "enter"
      ? "Enter"
      : parsed.key.length === 1
        ? parsed.key
        : parsed.key[0].toUpperCase() + parsed.key.slice(1);
  return [
    parsed.mod ? "Mod" : "",
    parsed.ctrl ? "Ctrl" : "",
    parsed.alt ? "Alt" : "",
    parsed.shift ? "Shift" : "",
    key,
  ]
    .filter(Boolean)
    .join("-");
}

/** Electron accelerator ("CmdOrCtrl+Shift+K") for the client menu. */
export function comboToAccelerator(combo: string): string | null {
  const parsed = parseCombo(combo);
  // Electron accelerators cover F1–F24 as well as Enter and single keys —
  // a client-menu binding remapped onto an F-key keeps its accelerator.
  const key =
    parsed.key === "enter"
      ? "Enter"
      : parsed.key === "`"
        ? "`"
        : functionKey(parsed.key)
          ? parsed.key.toUpperCase()
          : parsed.key.length === 1
            ? parsed.key.toUpperCase()
            : null;
  if (!key) return null;
  return [
    parsed.mod ? "CmdOrCtrl" : "",
    parsed.ctrl && !parsed.mod ? "Ctrl" : "",
    parsed.alt ? "Alt" : "",
    parsed.shift ? "Shift" : "",
    key,
  ]
    .filter(Boolean)
    .join("+");
}
