const UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}";
const MANAGED_PATH = new RegExp(
  String.raw`(?:^|/)(?:dala-paste/paste-[A-Za-z0-9._-]+|tmp/attachments/${UUID}/[A-Za-z0-9._-]+)$`,
);
const TOKEN = /"([^"]+)"|(\S+)/g;

export type AgentAttachments = {
  paths: string[];
  rest: string;
};

export type AttachmentSegment =
  | { type: "text"; value: string }
  | { type: "path"; value: string };

function managedAttachmentPath(path: string): boolean {
  return MANAGED_PATH.test(path.replaceAll("\\", "/"));
}

/**
 * Split composer text into an ordered stream of text runs and Dala-managed
 * attachment paths. Quoted tokens preserve Windows paths containing spaces.
 * Ordinary project paths stay inside the text runs, and order is preserved so
 * agent attachment chips land where the user placed the images.
 */
export function splitAgentAttachments(text: string): AttachmentSegment[] {
  const segments: AttachmentSegment[] = [];
  let cursor = 0;

  const pushText = (value: string) => {
    const cleaned = value.replace(/[ \t]{2,}/g, " ");
    if (cleaned.trim() !== "") segments.push({ type: "text", value: cleaned.trim() });
  };

  for (const match of text.matchAll(TOKEN)) {
    const path = match[1] ?? match[2];
    if (!managedAttachmentPath(path)) continue;

    const start = match.index ?? 0;
    const end = start + match[0].length;
    const before = start === 0 ? "" : text[start - 1];
    const after = end === text.length ? "" : text[end];

    if ((before && !/\s/.test(before)) || (after && !/\s/.test(after))) continue;

    pushText(text.slice(cursor, start));
    segments.push({ type: "path", value: path });
    cursor = end;
  }

  pushText(text.slice(cursor));
  return segments;
}

/** Flattened view of `splitAgentAttachments` for callers that only need the
 * path list and the remaining prompt. */
export function extractAgentAttachments(text: string): AgentAttachments {
  const segments = splitAgentAttachments(text);
  const paths = segments.filter((s) => s.type === "path").map((s) => s.value);
  if (paths.length === 0) return { paths, rest: text };
  return {
    paths,
    rest: segments
      .filter((s) => s.type === "text")
      .map((s) => s.value)
      .join(" ")
      .trim(),
  };
}
