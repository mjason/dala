const UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}";

const attachmentPathPattern = new RegExp(
  String.raw`/[^\s]*/(?:dala-paste/paste-[A-Za-z0-9._-]+|tmp/attachments/${UUID}/[A-Za-z0-9._-]+)`,
  "g",
);

export type AgentAttachments = {
  paths: string[];
  rest: string;
};

/**
 * Pull only Dala-managed attachment paths out of composer text. Ordinary
 * project paths must stay in the prompt so agents do not treat them as
 * freshly uploaded files.
 */
export function extractAgentAttachments(text: string): AgentAttachments {
  const paths: string[] = [];
  const remaining: string[] = [];
  let cursor = 0;

  for (const match of text.matchAll(attachmentPathPattern)) {
    const path = match[0];
    const start = match.index ?? 0;
    const end = start + path.length;
    const before = start === 0 ? "" : text[start - 1];
    const after = end === text.length ? "" : text[end];

    if ((before && !/\s/.test(before)) || (after && !/\s/.test(after))) continue;

    remaining.push(text.slice(cursor, start));
    paths.push(path);
    cursor = end;
  }

  if (paths.length === 0) return { paths, rest: text };

  remaining.push(text.slice(cursor));
  return {
    paths,
    rest: remaining.join("").replace(/[ \t]{2,}/g, " ").trim(),
  };
}
