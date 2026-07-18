/**
 * Upload markers: the placeholder tokens the composer inserts at the
 * paste/drop position while a file uploads (`⟨upload:7⟩`), swapped for the
 * uploaded paths when the upload resolves.
 *
 * This module is the ONLY authority on the marker format and on the text
 * edits around it — the recurring "image landed in the wrong place" bugs
 * all came from call sites hand-rolling pieces of this logic.
 */

let counter = 0;

/** A fresh, unique placeholder token. */
export function createMarker(): string {
  return `⟨upload:${++counter}⟩`;
}

/** Matches any marker, resolved or orphaned. */
export const MARKER_RE = /⟨upload:\d+⟩ ?/g;

/**
 * Outgoing text must NEVER carry markers: sending or stashing while an
 * upload is still in flight strips them (the upload later appends its
 * paths to whatever draft remains — see the upload queue).
 */
export function stripMarkers(text: string): string {
  return text.replace(MARKER_RE, "");
}

/** Replace the first occurrence of `marker`; null when it is gone. */
export function replaceMarkerIn(text: string, marker: string, replacement: string): string | null {
  const index = text.indexOf(marker);
  if (index === -1) return null;
  return text.slice(0, index) + replacement + text.slice(index + marker.length);
}

/**
 * Append `addition` to `text` with exactly one separating space (the shared
 * spacing rule for attach-button uploads, late-resolving uploads, and every
 * other "add to the end" path).
 */
export function appendWithSpace(text: string, addition: string): string {
  if (addition === "") return text;
  if (text === "" || text.endsWith(" ") || text.endsWith("\n")) return text + addition;
  return `${text} ${addition}`;
}

/** The pasted representation of uploaded paths (trailing space so the user
 * can keep typing right after). */
export function pathsText(paths: string[]): string {
  return paths.length > 0 ? paths.join(" ") + " " : "";
}
