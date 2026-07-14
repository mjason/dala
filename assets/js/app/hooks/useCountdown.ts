import { useCallback, useEffect, useState } from "react";

/**
 * Seconds-granular auto-hide countdown for banners/tips: `start(n)` shows
 * n and ticks down once per second; `seconds` turns null when it expires
 * (or `clear()` hides it immediately — the manual ×). The interval lives
 * in an effect, so unmount always cleans it up — unlike a raw setTimeout
 * captured in an event-handler closure, this cannot leak or go stale.
 */
export function useCountdown(): {
  seconds: number | null;
  start: (seconds: number) => void;
  clear: () => void;
} {
  const [seconds, setSeconds] = useState<number | null>(null);
  const running = seconds != null;

  useEffect(() => {
    if (!running) return;
    const timer = window.setInterval(() => {
      setSeconds((current) => (current == null || current <= 1 ? null : current - 1));
    }, 1000);
    return () => window.clearInterval(timer);
  }, [running]);

  // Stable identities: safe to capture in long-lived effect closures
  // (TerminalView's per-session setup effect holds them across renders).
  const start = useCallback((value: number) => setSeconds(value), []);
  const clear = useCallback(() => setSeconds(null), []);

  return { seconds, start, clear };
}
