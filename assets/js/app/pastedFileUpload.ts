import { savePastedFile } from "../ash_rpc";
import { call } from "./rpc";
import { fileToBase64, pasteName } from "./pasteFiles";

/**
 * Pasting or dropping files (screenshots for Claude Code & co): upload each
 * to the server's temp dir; resolves to the absolute paths that made it.
 * Failures are reported through `onError` and skipped.
 */
export async function uploadPastedFiles(
  files: File[],
  onError: (message: string) => void,
): Promise<string[]> {
  const paths: string[] = [];
  for (const file of files) {
    try {
      const contentBase64 = await fileToBase64(file);
      const result = await call<{ path: string }>(savePastedFile, {
        input: { name: pasteName(file), contentBase64 },
        fields: ["path"],
      });
      if (result.ok) {
        paths.push(result.data.path);
      } else {
        onError(result.error || "could not upload pasted file");
      }
    } catch (error) {
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
