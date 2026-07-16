import { buildCSRFHeaders } from "../ash_rpc";

export const DRAWER_UPLOAD_MAX_BYTES = 2 * 1024 * 1024 * 1024;
export const BROWSER_ATTACHMENT_MAX_BYTES = 512 * 1024 * 1024;

export type UploadLimit = {
  maxBytes: number;
  maxLabel: string;
};

export type UploadLimits = {
  drawerUpload: UploadLimit;
  browserAttachment: UploadLimit;
};

export const DEFAULT_UPLOAD_LIMITS: UploadLimits = {
  drawerUpload: { maxBytes: DRAWER_UPLOAD_MAX_BYTES, maxLabel: "2 GB" },
  browserAttachment: { maxBytes: BROWSER_ATTACHMENT_MAX_BYTES, maxLabel: "512 MB" },
};

export type UploadProgress = {
  fileName: string;
  fileIndex: number;
  fileCount: number;
  loaded: number;
  total: number;
  percent: number;
};

export type UploadedFile = {
  path: string;
  name?: string;
  size: number;
};

export class UploadError extends Error {}

function parseLimit(value: unknown): UploadLimit | null {
  if (typeof value !== "object" || value === null) return null;
  const limit = value as Record<string, unknown>;
  if (
    typeof limit.max_bytes !== "number" ||
    !Number.isSafeInteger(limit.max_bytes) ||
    limit.max_bytes <= 0 ||
    typeof limit.max_label !== "string" ||
    limit.max_label === ""
  ) {
    return null;
  }
  return { maxBytes: limit.max_bytes, maxLabel: limit.max_label };
}

/**
 * Read the server's effective runtime limits. The defaults keep uploads usable
 * during a rolling upgrade where an older server does not expose this route.
 */
export async function loadUploadLimits(): Promise<UploadLimits> {
  try {
    const response = await fetch("/files/limits", {
      cache: "no-store",
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) return DEFAULT_UPLOAD_LIMITS;

    const body = (await response.json()) as Record<string, unknown>;
    const drawerUpload = parseLimit(body.drawer_upload);
    const browserAttachment = parseLimit(body.browser_attachment);
    if (!drawerUpload || !browserAttachment) return DEFAULT_UPLOAD_LIMITS;
    return { drawerUpload, browserAttachment };
  } catch {
    return DEFAULT_UPLOAD_LIMITS;
  }
}

export function isUploadAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError";
}

export function uploadMultipartFile(opts: {
  url: string;
  file: File;
  fields?: Record<string, string>;
  maxBytes: number;
  maxLabel: string;
  signal?: AbortSignal;
  onProgress?: (loaded: number, total: number) => void;
}): Promise<UploadedFile> {
  const { url, file, fields = {}, maxBytes, maxLabel, signal, onProgress } = opts;
  if (file.size > maxBytes) {
    return Promise.reject(new UploadError(`${file.name}: file exceeds the ${maxLabel} limit`));
  }
  if (signal?.aborted) return Promise.reject(new DOMException("Upload cancelled", "AbortError"));

  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const form = new FormData();
    for (const [name, value] of Object.entries(fields)) form.append(name, value);
    form.append("file", file);

    const abort = () => xhr.abort();
    const finish = (callback: () => void) => {
      signal?.removeEventListener("abort", abort);
      callback();
    };

    xhr.open("POST", url);
    for (const [name, value] of Object.entries(
      buildCSRFHeaders({ Accept: "application/json" }),
    )) {
      xhr.setRequestHeader(name, value);
    }

    xhr.upload.onprogress = (event) => {
      const total = file.size;
      onProgress?.(Math.min(event.loaded, total), total);
    };
    xhr.onload = () => {
      let body: Record<string, unknown> = {};
      try {
        body = JSON.parse(xhr.responseText || "{}") as Record<string, unknown>;
      } catch {
        // A proxy may replace the JSON error body; keep the status fallback.
      }

      if (xhr.status >= 200 && xhr.status < 300 && typeof body.path === "string") {
        onProgress?.(file.size, file.size);
        finish(() =>
          resolve({
            path: body.path as string,
            name: typeof body.name === "string" ? body.name : undefined,
            size: typeof body.size === "number" ? body.size : file.size,
          }),
        );
      } else {
        const message =
          typeof body.error === "string"
            ? body.error
            : xhr.status === 413
              ? `${file.name}: file exceeds the ${maxLabel} limit`
              : `could not upload ${file.name} (HTTP ${xhr.status})`;
        finish(() => reject(new UploadError(message)));
      }
    };
    xhr.onerror = () => finish(() => reject(new UploadError(`could not upload ${file.name}`)));
    xhr.onabort = () =>
      finish(() => reject(new DOMException("Upload cancelled", "AbortError")));

    signal?.addEventListener("abort", abort, { once: true });
    onProgress?.(0, file.size);
    xhr.send(form);
  });
}

export function batchProgress(
  file: File,
  fileIndex: number,
  fileCount: number,
  loaded: number,
  total: number,
): UploadProgress {
  return {
    fileName: file.name || "attachment",
    fileIndex,
    fileCount,
    loaded,
    total,
    percent: total === 0 ? 100 : Math.min(100, Math.round((loaded / total) * 100)),
  };
}
