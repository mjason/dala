import {
  batchProgress,
  isUploadAbort,
  loadUploadLimits,
  uploadMultipartFile,
  type UploadProgress,
} from "./fileUpload";

/**
 * Pasting or dropping files (screenshots for Claude Code & co): upload each
 * to the server's temp dir; resolves to the absolute paths that made it.
 * Failures are reported through `onError` and skipped.
 */
export async function uploadPastedFiles(
  files: File[],
  onError: (message: string) => void,
  opts: { signal?: AbortSignal; onProgress?: (progress: UploadProgress) => void } = {},
): Promise<string[]> {
  const paths: string[] = [];
  const { browserAttachment } = await loadUploadLimits();
  for (const [index, file] of files.entries()) {
    if (opts.signal?.aborted) break;
    try {
      const result = await uploadMultipartFile({
        url: "/files/attachment",
        file,
        maxBytes: browserAttachment.maxBytes,
        maxLabel: browserAttachment.maxLabel,
        signal: opts.signal,
        onProgress: (loaded, total) =>
          opts.onProgress?.(batchProgress(file, index + 1, files.length, loaded, total)),
      });
      paths.push(result.path);
    } catch (error) {
      if (isUploadAbort(error)) break;
      onError(error instanceof Error ? error.message : "could not read file");
    }
  }
  return paths;
}

/** The text pasted into the terminal for the uploaded paths (trailing space
 * so the user can keep typing right after). */
export function pastedPathsText(paths: string[]): string {
  return paths.join(" ") + " ";
}
