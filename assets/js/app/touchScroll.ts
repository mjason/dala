/**
 * Touch-pan → terminal-scroll math (pure; DOM wiring lives in TerminalView).
 *
 * Why this exists: xterm 6 dropped ALL touch handling. v5's `.xterm-viewport`
 * was a native `overflow-y: scroll` element, so phones could pan it for free;
 * v6 replaced it with VS Code's ScrollableElement, which listens to `wheel`
 * events only — a one-finger pan over the terminal does nothing on mobile.
 *
 * Conventions:
 * - `dy` (finger movement, px): positive = finger moved DOWN.
 * - `scrollPx`: positive = viewport moves DOWN toward the bottom of the
 *   scrollback (natural scrolling: content follows the finger, so
 *   `scrollPx = -dy`).
 * - `lines`: positive = scroll down — matches both `term.scrollLines()` and
 *   WheelEvent `deltaY > 0`.
 */

/** Finger must travel this far before the gesture commits to an axis. */
export const PAN_SLOP_PX = 8;
/** Flick detection: minimum velocity (px/ms) at touchend to start coasting. */
export const FLICK_MIN_VELOCITY = 0.25;
/** A flick only counts when the last move was this recent (ms) — resting the
 * finger before lifting must not coast. */
export const FLICK_MAX_GAP_MS = 120;
/** Inertia stops below this velocity (px/ms). */
export const MIN_COAST_VELOCITY = 0.05;
/** Exponential decay time constant for inertia (ms) — iOS-like feel. */
const INERTIA_TAU_MS = 325;

/** One inertia step: velocity after `dtMs` of exponential decay. */
export function decayVelocity(velocity: number, dtMs: number): number {
  if (dtMs <= 0) return velocity;
  return velocity * Math.exp(-dtMs / INERTIA_TAU_MS);
}

/**
 * Where a pan must be routed to behave like a mouse wheel would:
 * - "lines": normal scrollback — scroll the viewport directly
 *   (`term.scrollLines`), 1 touch px ≈ 1 scroll px with line quantization.
 * - "wheel": alt-screen TUIs and mouse-tracking apps — dispatch synthetic
 *   WheelEvents on `.xterm` so xterm's own wheel logic applies (alt-buffer
 *   wheel→arrow-key conversion, or mouse reports when the app enabled a
 *   wheel-capable mouse protocol).
 * X10 tracking has no wheel reports, so it only routes to "wheel" when the
 * alt buffer is active (where xterm falls back to arrow conversion).
 */
export function touchScrollRoute(
  bufferType: "normal" | "alternate",
  mouseTracking: "none" | "x10" | "vt200" | "drag" | "any",
): "lines" | "wheel" {
  if (mouseTracking === "vt200" || mouseTracking === "drag" || mouseTracking === "any") {
    return "wheel";
  }
  return bufferType === "alternate" ? "wheel" : "lines";
}

/** Converts scroll pixels into whole lines, carrying the remainder so slow
 * pans still accumulate into full lines instead of being dropped. */
export type LineAccumulator = {
  /** Feed scroll pixels; returns whole lines to scroll now (may be 0). */
  add(scrollPx: number, cellHeightPx: number): number;
  reset(): void;
};

export function createLineAccumulator(): LineAccumulator {
  let carry = 0;
  return {
    add(scrollPx: number, cellHeightPx: number): number {
      if (!(cellHeightPx > 0)) return 0;
      carry += scrollPx;
      const lines = Math.trunc(carry / cellHeightPx);
      carry -= lines * cellHeightPx;
      return lines;
    },
    reset() {
      carry = 0;
    },
  };
}

export type PanMove =
  /** Within the slop radius — nothing decided, nothing hijacked. */
  | { phase: "pending" }
  /** Committed to a horizontal gesture (or aborted): leave it alone. */
  | { phase: "ignored" }
  /** Vertical pan we own; scrollPx > 0 = scroll toward the bottom. */
  | { phase: "pan"; scrollPx: number };

export type TouchPan = {
  start(x: number, y: number, timeMs: number): void;
  move(x: number, y: number, timeMs: number): PanMove;
  /** Flick velocity in scrollPx/ms (0 = no flick / not a pan). */
  end(timeMs: number): number;
  /** Abort the gesture (second finger landed, touchcancel, …). */
  cancel(): void;
};

/**
 * Single-finger gesture state machine with axis lock: taps (never exceeding
 * the slop) and horizontal pans are reported as pending/ignored so focus,
 * selection and any horizontal behavior stay untouched.
 */
export function createTouchPan(slopPx: number = PAN_SLOP_PX): TouchPan {
  let phase: "idle" | "pending" | "pan" | "ignored" = "idle";
  let startX = 0;
  let startY = 0;
  let lastY = 0;
  let lastTime = 0;
  let velocity = 0; // scrollPx/ms, exponentially blended

  return {
    start(x, y, timeMs) {
      phase = "pending";
      startX = x;
      startY = y;
      lastY = y;
      lastTime = timeMs;
      velocity = 0;
    },

    move(x, y, timeMs): PanMove {
      if (phase === "idle" || phase === "ignored") return { phase: "ignored" };
      if (phase === "pending") {
        const dx = Math.abs(x - startX);
        const dyAbs = Math.abs(y - startY);
        if (Math.max(dx, dyAbs) < slopPx) return { phase: "pending" };
        if (dx > dyAbs) {
          phase = "ignored";
          return { phase: "ignored" };
        }
        phase = "pan";
        // Consume the slop: the first pan step starts from here, so the
        // content doesn't jump by the slop distance.
        lastY = y;
        lastTime = timeMs;
        return { phase: "pan", scrollPx: 0 };
      }
      const scrollPx = -(y - lastY);
      const dt = timeMs - lastTime;
      if (dt > 0) {
        const sample = scrollPx / dt;
        velocity = velocity === 0 ? sample : 0.7 * sample + 0.3 * velocity;
      }
      lastY = y;
      lastTime = timeMs;
      return { phase: "pan", scrollPx };
    },

    end(timeMs) {
      const wasPan = phase === "pan";
      const recent = timeMs - lastTime <= FLICK_MAX_GAP_MS;
      const v = velocity;
      phase = "idle";
      velocity = 0;
      if (!wasPan || !recent || Math.abs(v) < FLICK_MIN_VELOCITY) return 0;
      return v;
    },

    cancel() {
      phase = "ignored";
      velocity = 0;
    },
  };
}
