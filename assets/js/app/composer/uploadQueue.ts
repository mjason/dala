import type { UploadProgress } from "../fileUpload";
import { appendWithSpace, pathsText, replaceMarkerIn } from "./markers";

/**
 * The composer's upload lifecycle, in one place.
 *
 * Invariants this module owns (each earned by a real bug):
 * - CONCURRENT batches are all processed — a paste during another upload
 *   used to be silently dropped, leaving its placeholder as literal text.
 * - A marker is ALWAYS consumed exactly once: swapped for the uploaded
 *   paths in the live editor, else in the saved draft, else (marker gone —
 *   the text was sent or the user deleted it) the paths append to the end
 *   of whatever draft remains. Total failure consumes it with "".
 * - Draft cleanup runs even after the composer unmounted — drafts outlive
 *   the editor, and an orphaned `⟨upload:n⟩` in a saved draft is garbage
 *   the user has to delete by hand.
 */

export type UploadTarget = {
  /** Swap `marker` inside the LIVE editor; false when the editor is gone
   * or the user deleted the marker. */
  replaceInEditor: (marker: string, replacement: string) => boolean;
  readDraft: () => string;
  setDraft: (next: string) => void;
};

export type UploadQueue = {
  /** Upload `files`; `marker` is the placeholder already sitting in the
   * text (paste/drop), absent for the attach button (append semantics). */
  enqueue: (files: File[], marker?: string) => Promise<void>;
  /** Abort every in-flight batch (markers still get consumed). */
  abortAll: () => void;
  pending: () => boolean;
};

export function createUploadQueue(deps: {
  target: UploadTarget;
  upload: (
    files: File[],
    opts: { signal: AbortSignal; onProgress: (progress: UploadProgress) => void },
  ) => Promise<string[]>;
  /** Progress for the UI; null when the last batch settles. */
  onProgress: (progress: UploadProgress | null) => void;
}): UploadQueue {
  const { target, upload, onProgress } = deps;
  const controllers = new Set<AbortController>();

  const settle = (marker: string | undefined, paths: string[]) => {
    const replacement = pathsText(paths);
    if (marker) {
      if (target.replaceInEditor(marker, replacement)) return;
      const draft = replaceMarkerIn(target.readDraft(), marker, replacement);
      if (draft != null) {
        target.setDraft(draft);
        return;
      }
    }
    // No marker (attach button), or the marker is gone (sent / deleted):
    // the uploads still succeeded — surface them at the end of the draft.
    if (replacement !== "") target.setDraft(appendWithSpace(target.readDraft(), replacement));
  };

  return {
    async enqueue(files, marker) {
      if (files.length === 0) {
        if (marker) settle(marker, []);
        return;
      }
      const controller = new AbortController();
      controllers.add(controller);
      try {
        const paths = await upload(files, {
          signal: controller.signal,
          onProgress,
        });
        settle(marker, paths);
      } catch {
        // upload() is not expected to throw (uploadPastedFiles reports and
        // swallows) — but a marker must be consumed no matter what.
        settle(marker, []);
      } finally {
        controllers.delete(controller);
        if (controllers.size === 0) onProgress(null);
      }
    },
    abortAll() {
      for (const controller of controllers) controller.abort();
    },
    pending() {
      return controllers.size > 0;
    },
  };
}
