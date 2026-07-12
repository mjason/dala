import { useState } from "react";
import { buildCSRFHeaders, deleteEntry } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
import type { DeleteTarget } from "./tree";

/**
 * File operations on the drawer: multipart uploads (button, paste, drop)
 * and entry deletion — both refresh the destination directory afterwards.
 */
export function useFileOps(opts: {
  onError: (message: string) => void;
  refreshDir: (dir: string) => Promise<void>;
  expandDir: (dir: string) => void;
  /** Clear selection/preview for an entry that was just deleted. */
  onDeleted: (target: DeleteTarget) => void;
}) {
  const { onError, refreshDir, expandDir, onDeleted } = opts;
  const { t } = useI18n();
  const [uploading, setUploading] = useState(false);

  const uploadTo = async (dir: string, files: File[]) => {
    if (files.length === 0) return;
    setUploading(true);

    for (const file of files) {
      const form = new FormData();
      form.append("dir", dir);
      form.append("file", file);

      try {
        const response = await fetch("/files/upload", {
          method: "POST",
          headers: buildCSRFHeaders(),
          body: form,
        });
        if (!response.ok) {
          let message = t("uploadFailed");
          try {
            message = (await response.json()).error ?? message;
          } catch {
            // Non-JSON error body: keep the generic message.
          }
          onError(message);
        }
      } catch {
        onError(t("uploadFailed"));
      }
    }

    setUploading(false);
    await refreshDir(dir);
    // Make the destination visible so the new files show up immediately.
    expandDir(dir);
  };

  const deleteEntryAt = async (target: DeleteTarget) => {
    const result = await call<unknown>(deleteEntry, {
      input: { path: target.path },
      fields: ["path"],
    });
    if (!result.ok) {
      onError(result.error || t("somethingWentWrong"));
      return;
    }

    onDeleted(target);
    await refreshDir(target.parentDir);
  };

  return { uploading, uploadTo, deleteEntryAt };
}
