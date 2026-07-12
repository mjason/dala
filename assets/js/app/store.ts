/**
 * localStorage-backed preference store — the one JSON round-trip.
 *
 * Every prefs module (speech, terminal, …) used to hand-roll the same
 * try/catch + JSON.parse + defaults-on-garbage + merge-and-persist dance.
 * `createStore` owns it once:
 *
 *   const store = createStore(KEY, DEFAULTS, normalize, { event: EVENT });
 *   store.load();            // defaults on missing/garbage/thrown storage
 *   store.save({ size: 3 }); // merge → normalize → persist → broadcast
 *
 * `normalize` (optional) validates/clamps the merged value — it runs on
 * every load AND before every save, so garbage never escapes. Without it,
 * stored values are shallow-merged over the defaults, keeping only keys
 * that exist in the defaults. `options.event` broadcasts the merged value
 * as a window CustomEvent after each save (even when the write fails —
 * live listeners should still see the change).
 *
 * Raw-string stores (notifyPrefs "off", i18n lang, Windowed mode) are NOT
 * built on this — they store bare strings, not JSON objects.
 */

export type Store<T> = {
  load(): T;
  save(patch: Partial<T>): T;
};

export function createStore<T extends Record<string, unknown>>(
  key: string,
  defaults: T,
  normalize?: (raw: Partial<T>) => T,
  options: { event?: string } = {},
): Store<T> {
  const norm =
    normalize ??
    ((raw: Partial<T>): T => {
      const out = { ...defaults };
      for (const k of Object.keys(defaults) as (keyof T)[]) {
        if (k in raw && raw[k] !== undefined) out[k] = raw[k] as T[keyof T];
      }
      return out;
    });

  function load(): T {
    try {
      const parsed: unknown = JSON.parse(localStorage.getItem(key) ?? "{}");
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        return { ...defaults };
      }
      return norm(parsed as Partial<T>);
    } catch {
      return { ...defaults };
    }
  }

  function save(patch: Partial<T>): T {
    const merged = norm({ ...load(), ...patch });
    try {
      localStorage.setItem(key, JSON.stringify(merged));
    } catch {
      // storage unavailable — still apply live
    }
    if (options.event) {
      window.dispatchEvent(new CustomEvent(options.event, { detail: merged }));
    }
    return merged;
  }

  return { load, save };
}
