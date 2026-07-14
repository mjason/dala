/**
 * Server-upgrade detection for a long-lived SPA tab: the page embeds the
 * server version at load time (meta[name="dala-version"], read by meta.ts);
 * after a Phoenix socket reconnect — the one signal that the server may
 * have restarted — we ask GET /version what it runs NOW and compare. No
 * polling: reconnects are the only trigger.
 */

/** True when both versions are known and differ (whitespace ignored). */
export function serverChanged(embedded: string | null, fetched: string | null): boolean {
  const before = embedded?.trim();
  const after = fetched?.trim();
  return Boolean(before && after && before !== after);
}

/** The version the server runs right now, or null when unreachable/odd. */
export async function fetchServerVersion(): Promise<string | null> {
  try {
    const response = await fetch("/version", { cache: "no-store" });
    if (!response.ok) return null;
    const text = (await response.text()).trim();
    return text || null;
  } catch {
    // Server still restarting or network blip — a later reconnect retries.
    return null;
  }
}

/** One reconnect-triggered check: did the server change under this page? */
export async function checkServerUpdated(embedded: string | null): Promise<boolean> {
  if (!embedded?.trim()) return false; // nothing to compare against — stay quiet
  return serverChanged(embedded, await fetchServerVersion());
}
