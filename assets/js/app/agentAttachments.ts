const UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}";

const attachmentPathPattern = new RegExp(
  String.raw`/[^\s]*/(?:dala-paste/paste-[A-Za-z0-9._-]+|tmp/attachments/${UUID}/[A-Za-z0-9._-]+)`,
  "g",
);

export type AgentAttachments = {
  paths: string[];
  rest: string;
};

export type AttachmentSegment =
  | { type: "text"; value: string }
  | { type: "path"; value: string };

/**
 * Split composer text into an ordered stream of text runs and Dala-managed
 * attachment paths. Ordinary project paths stay inside the text runs so
 * agents do not treat them as freshly uploaded files. Order is preserved so
 * delivery can interleave paste frames — the agent's [Image #N] chips land
 * where the user actually placed the images, not all at the front.
 */
export function splitAgentAttachments(text: string): AttachmentSegment[] {
  const segments: AttachmentSegment[] = [];
  let cursor = 0;

  const pushText = (value: string) => {
    const cleaned = value.replace(/[ \t]{2,}/g, " ");
    if (cleaned.trim() !== "") segments.push({ type: "text", value: cleaned.trim() });
  };

  for (const match of text.matchAll(attachmentPathPattern)) {
    const path = match[0];
    const start = match.index ?? 0;
    const end = start + path.length;
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
