export type PreviewKind = "text" | "json" | "csv" | "spreadsheet" | "html" | "image";

const IMAGE_EXTENSIONS = new Set([
  "png",
  "jpg",
  "jpeg",
  "gif",
  "webp",
  "svg",
  "ico",
  "bmp",
  "avif",
]);

export function previewKind(fileName: string): PreviewKind {
  const ext = fileName.split(".").pop()?.toLowerCase() ?? "";

  if (IMAGE_EXTENSIONS.has(ext)) return "image";
  if (ext === "json") return "json";
  // JSONC is code, not JSON — the JSON pretty-printer would reject comments.
  if (ext === "jsonc") return "text";
  if (ext === "csv" || ext === "tsv") return "csv";
  if (ext === "xlsx" || ext === "xlsm") return "spreadsheet";
  if (ext === "html" || ext === "htm") return "html";
  return "text";
}

/** URL of the raw-file endpoint (inline view or download). */
export function rawFileUrl(path: string, download = false): string {
  const query = new URLSearchParams({ path });
  if (download) query.set("download", "1");
  return `/files/raw?${query.toString()}`;
}
