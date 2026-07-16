import { useCallback, useEffect, useRef, useState } from "react";
import { gitStatus } from "../../ash_rpc";
import type { GitStatusFields } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
import type { Status } from "../gitPanel/types";
import { useFileWatcher } from "./useFileWatcher";

const STATUS_FIELDS = ["repo", "root", "branch", "files", "ignored"] as unknown as GitStatusFields;
const DEFAULT_POLL_MS = 5000;

type Options = {
  watch?: boolean;
  pollMs?: number;
};

function statusKey(status: Status): string {
  return JSON.stringify([
    status.repo,
    status.root,
    status.branch,
    status.files.map((file) => [file.path, file.status, file.staged, file.unstaged]),
    status.ignored,
  ]);
}

/** Git status with stale-request protection and event-driven refreshes. */
export function useGitStatus(
  path: string,
  onError: (message: string) => void,
  { watch = true, pollMs = DEFAULT_POLL_MS }: Options = {},
) {
  const { t } = useI18n();
  const errorRef = useRef(onError);
  errorRef.current = onError;
  const translateRef = useRef(t);
  translateRef.current = t;

  const [status, setStatus] = useState<Status | null>(null);
  const [loading, setLoading] = useState(false);
  const [version, setVersion] = useState(0);
  const [externalVersion, setExternalVersion] = useState(0);
  const requestRef = useRef(0);
  const visibleRequestRef = useRef(0);
  const statusKeyRef = useRef("");
  const activePathRef = useRef(path);
  activePathRef.current = path;
  const refreshTimerRef = useRef<number | undefined>(undefined);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      window.clearTimeout(refreshTimerRef.current);
    };
  }, []);

  const loadStatus = useCallback(
    async (silent = false) => {
      const request = ++requestRef.current;
      if (!silent) {
        visibleRequestRef.current = request;
        setLoading(true);
      }

      const result = await call<Status>(gitStatus, { input: { path }, fields: STATUS_FIELDS });
      if (!mountedRef.current) return result;

      if (visibleRequestRef.current === request) {
        visibleRequestRef.current = 0;
        setLoading(false);
      }
      if (activePathRef.current !== path || request !== requestRef.current) return result;

      if (result.ok) {
        const nextKey = statusKey(result.data);
        if (nextKey !== statusKeyRef.current) {
          statusKeyRef.current = nextKey;
          setStatus(result.data);
          setVersion((value) => value + 1);
        }
      } else if (!silent) {
        errorRef.current(result.error || translateRef.current("couldNotLoadGit"));
      }
      return result;
    },
    [path],
  );

  const refreshSoon = useCallback(
    (delay = 180) => {
      window.clearTimeout(refreshTimerRef.current);
      refreshTimerRef.current = window.setTimeout(() => void loadStatus(true), delay);
    },
    [loadStatus],
  );

  useEffect(() => {
    activePathRef.current = path;
    requestRef.current += 1;
    visibleRequestRef.current = 0;
    statusKeyRef.current = "";
    setStatus(null);
    setVersion(0);
    setExternalVersion(0);
    setLoading(false);
    window.clearTimeout(refreshTimerRef.current);
    void loadStatus();
  }, [path, loadStatus]);

  const watchRoot = watch ? (status?.root ?? path) : null;
  useFileWatcher(
    watchRoot,
    watchRoot ? [watchRoot] : [],
    () => {
      setExternalVersion((value) => value + 1);
      refreshSoon();
    },
    () => {
      setExternalVersion((value) => value + 1);
      refreshSoon(0);
    },
  );

  // Native watchers are immediate. This low-frequency visible-tab check is
  // only a safety net for mtime-poll fallback and missed kernel events.
  useEffect(() => {
    if (pollMs <= 0) return;
    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") void loadStatus(true);
    }, pollMs);
    return () => window.clearInterval(timer);
  }, [loadStatus, pollMs]);

  return { status, loading, version, externalVersion, loadStatus, refreshSoon };
}
