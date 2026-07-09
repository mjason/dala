/**
 * Helpers for pasting/dropping files (typically screenshots) into the
 * terminal. The file is uploaded to the server, which stores it in a temp
 * dir; the returned absolute path is then pasted into the PTY so CLI tools
 * (Claude Code, codex, opencode) pick it up as a file reference — the same
 * mechanism as dragging a file onto a native terminal.
 */

export function collectTransferFiles(dt: DataTransfer | null): File[] {
  if (!dt) return [];

  if (dt.items && dt.items.length > 0) {
    return Array.from(dt.items)
      .filter((item) => item.kind === "file")
      .map((item) => item.getAsFile())
      .filter((file): file is File => file != null);
  }

  return dt.files ? Array.from(dt.files) : [];
}

export function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const url = String(reader.result ?? "");
      const marker = url.indexOf("base64,");
      if (marker >= 0) resolve(url.slice(marker + "base64,".length));
      else reject(new Error("unexpected data url"));
    };
    reader.onerror = () => reject(reader.error ?? new Error("could not read file"));
    reader.readAsDataURL(file);
  });
}

/** Filename hint for the server; only its extension is used. */
export function pasteName(file: File): string {
  return file.name || file.type || "png";
}
