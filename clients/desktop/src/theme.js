// Native-shell theming. The client is a pure web loader: the PAGE owns the
// theme truth (it resolves follow-system + manual override and reports the
// EFFECTIVE theme via the `set_theme` IPC). The main process only reacts —
// it never inspects the system scheme itself.
//
// Kept as a pure module (no electron require) so it unit-tests with a mocked
// nativeTheme, same pattern as src/config.js.

// Window background per theme — matches --color-bg0 in assets/css/app.css
// (dark #0b0c0e / light #fbfbfa). Set on the BrowserWindow so a resize or a
// reload never flashes the opposite shade behind the page.
const THEME_BG = { light: "#fbfbfa", dark: "#0b0c0e" };

/** Accept only the two effective themes; anything else → null (ignored). */
function normalizeTheme(theme) {
  return theme === "light" || theme === "dark" ? theme : null;
}

/** Background color for a theme (dark for unknown input, so callers can seed
 * a window before the first page report arrives). */
function backgroundFor(theme) {
  return THEME_BG[normalizeTheme(theme)] || THEME_BG.dark;
}

/**
 * Cold-start effective theme, from the OS, for seeding the FIRST shell window
 * before the page has reported its own (the page owns the real truth:
 * follow-system + manual override). Without this the window was hardcoded to
 * "dark", so a light-OS user flashed a dark window/titlebar until set_theme
 * arrived. `nativeTheme.shouldUseDarkColors` reflects the OS scheme once the
 * app is ready; dark on a missing nativeTheme (the app has always been dark).
 */
function coldStartTheme(nativeTheme) {
  if (!nativeTheme) return "dark";
  return nativeTheme.shouldUseDarkColors ? "dark" : "light";
}

/**
 * Apply an effective theme reported by the page to the native shell:
 *  - nativeTheme.themeSource drives the title bar / traffic lights / native
 *    scrollbars so the chrome matches the page;
 *  - each dala shell window's backgroundColor is repainted so it never peeks
 *    the wrong shade.
 * Returns the applied theme, or null when the input was not a valid theme.
 */
function applyTheme(nativeTheme, windows, theme) {
  const t = normalizeTheme(theme);
  if (!t) return null;
  if (nativeTheme) nativeTheme.themeSource = t;
  const bg = THEME_BG[t];
  for (const win of windows || []) {
    if (
      win &&
      !win.isDestroyed() &&
      win.isDalaShell &&
      typeof win.setBackgroundColor === "function"
    ) {
      win.setBackgroundColor(bg);
    }
  }
  return t;
}

module.exports = { THEME_BG, normalizeTheme, backgroundFor, coldStartTheme, applyTheme };
