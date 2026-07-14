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

/**
 * Floor for the empty/short editor, matched to the git commit box so the two
 * text inputs of the app read as one family. The commit box is a `rows={2}`
 * textarea: 2 × 19.5px (13px/1.5) + 12px padding + 2px border ≈ 53px. The
 * composer runs a bigger 14px/1.5 face and gets one line more of headroom:
 * 12px of `.cm-content` padding + ~3 × 21px lines ≈ 72px = 4.5rem (the box is
 * border-box, so the floor IS the rendered height). It used to be 7.5rem
 * (~5 lines), which ate terminal rows while sitting empty.
 */
export const COMPOSER_MIN_HEIGHT = "4.5rem";

/**
 * Coarse pointers type at 16px (iOS auto-zooms anything smaller), so the same
 * 3 lines need more room: 12px padding + 3 × 24px = 84px = 5.25rem. Phones
 * also have no hover affordances — a too-short tap target is worse there.
 */
export const COMPOSER_MIN_HEIGHT_TOUCH = "5.25rem";

/**
 * Growth cap: the terminal above must keep the clear majority of the view.
 * `40vh` alone lies when the soft keyboard is up — mobile `vh` ignores the
 * keyboard — so the cap also honors the VISUAL viewport, mirrored into
 * `--vvh` by index.tsx (`100vh` fallback where it isn't set). CSS `min()`
 * with `var()` inside `calc()` is plain CSS and passes through CodeMirror's
 * theme (style-mod) untouched.
 */
export const COMPOSER_MAX_HEIGHT = "min(40vh, calc(var(--vvh, 100vh) * 0.4))";

export function composerSizing(
  fullscreen: boolean,
  coarsePointer = false,
): Record<string, Record<string, string>> {
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
    ".cm-content": {
      minHeight: coarsePointer ? COMPOSER_MIN_HEIGHT_TOUCH : COMPOSER_MIN_HEIGHT,
    },
    ".cm-scroller": { overflowY: "auto" },
  };
}
