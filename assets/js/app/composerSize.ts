/**
 * The composer editor's height policy, as a CodeMirror theme spec.
 *
 * History: the composer once had a hard-FIXED height on purpose — growing on
 * every wrapped line reflowed the terminal (and its TUI) per keystroke. The
 * bounded design keeps that concern: the editor follows its content only
 * between a floor (the old fixed height) and a cap well under half the
 * viewport, so the terminal always stays visible; past the cap the editor
 * scrolls internally. Terminal refits on growth are debounced by the caller.
 *
 * Kept as a pure function: jsdom cannot lay out CodeMirror, so vitest pins
 * the policy here while e2e measures the real pixels.
 */

/** The old fixed height — short drafts render exactly as before. */
export const COMPOSER_MIN_HEIGHT = "7.5rem";

/**
 * Growth cap: the terminal above must keep the clear majority of the view.
 * `40vh` alone lies when the soft keyboard is up — mobile `vh` ignores the
 * keyboard — so the cap also honors the VISUAL viewport, mirrored into
 * `--vvh` by index.tsx (`100vh` fallback where it isn't set). CSS `min()`
 * with `var()` inside `calc()` is plain CSS and passes through CodeMirror's
 * theme (style-mod) untouched.
 */
export const COMPOSER_MAX_HEIGHT = "min(40vh, calc(var(--vvh, 100vh) * 0.4))";

export function composerSizing(fullscreen: boolean): Record<string, Record<string, string>> {
  if (fullscreen) {
    return {
      // The host is a definite-height flex child — fill it.
      "&": { height: "100%" },
      ".cm-scroller": { overflowY: "auto" },
    };
  }
  return {
    // No fixed height: CodeMirror sizes the editor to its content, bounded
    // by the cap; the floor lives on the content so the empty editor keeps
    // its familiar size.
    "&": { maxHeight: COMPOSER_MAX_HEIGHT },
    ".cm-content": { minHeight: COMPOSER_MIN_HEIGHT },
    ".cm-scroller": { overflowY: "auto" },
  };
}
