import { useEffect, useRef, useState } from "react";
import { copyEntry, deleteEntry, moveEntry, renameEntry } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
import {
  batchProgress,
  isUploadAbort,
  loadUploadLimits,
  uploadMultipartFile,
  type UploadProgress,
} from "../fileUpload";
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
  const [uploadProgress, setUploadProgress] = useState<UploadProgress | null>(null);
  const uploadAbortRef = useRef<AbortController | null>(null);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      uploadAbortRef.current?.abort();
    };
  }, []);

  const uploadTo = async (dir: string, files: File[]) => {
    if (files.length === 0) return;
    if (uploadAbortRef.current) return;
    const controller = new AbortController();
    uploadAbortRef.current = controller;
    setUploading(true);
    const { drawerUpload } = await loadUploadLimits();

    for (const [index, file] of files.entries()) {
      if (controller.signal.aborted) break;
      if (mountedRef.current) {
        setUploadProgress(batchProgress(file, index + 1, files.length, 0, file.size));
      }
      try {
        await uploadMultipartFile({
          url: "/files/upload",
          file,
          fields: { dir },
          maxBytes: drawerUpload.maxBytes,
          maxLabel: drawerUpload.maxLabel,
          signal: controller.signal,
          onProgress: (loaded, total) => {
            if (mountedRef.current) {
              setUploadProgress(batchProgress(file, index + 1, files.length, loaded, total));
            }
          },
        });
      } catch (error) {
        if (isUploadAbort(error)) break;
        onError(error instanceof Error ? error.message : t("uploadFailed"));
      }
    }

    uploadAbortRef.current = null;
    if (!mountedRef.current) return;
    setUploadProgress(null);
    setUploading(false);
    await refreshDir(dir);
    // Make the destination visible so the new files show up immediately.
    expandDir(dir);
  };

  const cancelUpload = () => uploadAbortRef.current?.abort();

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

  /** Rename in place; resolves to the new path, or null on failure. */
  const renameEntryAt = async (path: string, parentDir: string, name: string) => {
    const result = await call<{ path: string }>(renameEntry, {
      input: { path, name },
      fields: ["path"],
    });
    if (!result.ok) {
      onError(result.error || t("somethingWentWrong"));
      return null;
    }
    await refreshDir(parentDir);
    return result.data.path;
  };

  /** Copy an entry into a directory (collision-safe on the server). */
  const copyEntryTo = async (path: string, dir: string) => {
    const result = await call<{ path: string }>(copyEntry, {
      input: { path, dir },
      fields: ["path"],
    });
    if (!result.ok) {
      onError(result.error || t("somethingWentWrong"));
      return false;
    }
    await refreshDir(dir);
    expandDir(dir);
    return true;
  };

  /** Move an entry into a directory; refreshes both ends. */
  const moveEntryTo = async (path: string, parentDir: string, dir: string) => {
    const result = await call<{ path: string }>(moveEntry, {
      input: { path, dir },
      fields: ["path"],
    });
    if (!result.ok) {
      onError(result.error || t("somethingWentWrong"));
      return false;
    }
    await refreshDir(parentDir);
    await refreshDir(dir);
    expandDir(dir);
    return true;
  };

  return {
    uploading,
    uploadProgress,
    cancelUpload,
    uploadTo,
    deleteEntryAt,
    renameEntryAt,
    copyEntryTo,
    moveEntryTo,
  };
}
