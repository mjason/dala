import React from "react";
import { X } from "lucide-react";
import { humanBytes } from "./util";
import type { UploadProgress } from "./fileUpload";

export default function UploadProgressView({
  progress,
  onCancel,
  cancelLabel,
  className = "",
}: {
  progress: UploadProgress;
  onCancel: () => void;
  cancelLabel: string;
  className?: string;
}) {
  return (
    <div data-upload-progress role="status" className={`min-w-0 ${className}`}>
      <div className="flex min-w-0 items-start gap-2">
        <div className="min-w-0 flex-1">
          <div className="break-all font-mono text-[11px] leading-4 text-fg">
            {progress.fileName}
          </div>
          <div className="mt-0.5 flex items-center justify-between gap-2 font-mono text-[10px] tabular-nums text-fg-muted">
            <span>
              {progress.fileIndex}/{progress.fileCount}
            </span>
            <span>
              {humanBytes(progress.loaded)} / {humanBytes(progress.total)} · {progress.percent}%
            </span>
          </div>
        </div>
        <button
          type="button"
          data-cancel-upload
          aria-label={cancelLabel}
          title={cancelLabel}
          onClick={onCancel}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:bg-bg2 hover:text-danger"
        >
          <X className="h-3.5 w-3.5" />
        </button>
      </div>
      <div
        role="progressbar"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={progress.percent}
        className="mt-1.5 h-1 w-full overflow-hidden rounded-sm bg-bg2"
      >
        <div
          className="h-full bg-mint transition-[width] duration-100"
          style={{ width: `${progress.percent}%` }}
        />
      </div>
    </div>
  );
}
