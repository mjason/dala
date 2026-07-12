import { readFile } from "../ash_rpc";
import type { ReadFileFields } from "../ash_rpc";
import { previewKind } from "./fileTypes";
import { call } from "./rpc";
import type { Preview } from "./FilePreview";

const FILE_FIELDS: ReadFileFields = ["path", "size", "truncated", "binary", "content"];

/**
 * Loads a file into a `Preview` (images are served by URL, text is read via
 * RPC). Shared by the file drawer and the quick-open palette.
 */
export async function loadPreview(
  path: string,
  size = 0,
): Promise<{ ok: true; preview: Preview } | { ok: false; message: string | null }> {
  const kind = previewKind(path);

  if (kind === "image") {
    return { ok: true, preview: { kind: "image", path, size } };
  }

  const result = await call<{
    path: string;
    size: number;
    truncated: boolean;
    binary: boolean;
    content: string | null;
  }>(readFile, { input: { path }, fields: FILE_FIELDS });

  if (!result.ok) {
    return { ok: false, message: result.error || null };
  }

  const data = result.data;

  if (data.binary) {
    return { ok: true, preview: { kind: "binary", path: data.path, size: data.size } };
  }

  return {
    ok: true,
    preview: {
      kind,
      path: data.path,
      size: data.size,
      truncated: data.truncated,
      content: data.content ?? "",
    },
  };
}
