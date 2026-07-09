import { buildCSRFHeaders, readFile } from "../ash_rpc";
import type { ReadFileFields } from "../ash_rpc";
import { previewKind } from "./fileTypes";
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

  const result = await readFile({
    input: { path },
    fields: FILE_FIELDS,
    headers: buildCSRFHeaders(),
  });

  if (!result.success) {
    return { ok: false, message: result.errors[0]?.message ?? null };
  }

  const data = result.data as unknown as {
    path: string;
    size: number;
    truncated: boolean;
    binary: boolean;
    content: string | null;
  };

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
