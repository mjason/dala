import React, { useEffect, useRef, useState } from "react";
import { applyUpdate, checkUpdate, updateStatus } from "../ash_rpc";
import { call } from "./rpc";
import { useI18n } from "./i18n";
import { serverVersion } from "./meta";
import { onReconnect } from "./socket";

type Info = {
  enabled: boolean | null;
  current: string;
  latest: string | null;
  tag: string | null;
  updateAvailable: boolean | null;
  notesUrl: string | null;
  legacyEnvConfig?: boolean;
};

type ApplyResult = {
  attemptId: string;
  status: string;
  updatedTo: string;
};

type StatusResult = {
  attemptId: string | null;
  status: "pending" | "succeeded" | "failed" | "unknown";
  target: string | null;
  message: string | null;
  rolledBack: boolean | null;
};

type StoredAttempt = {
  attemptId: string;
  target: string;
  requestedAt: string;
};

type UpdateState = "idle" | "updating" | "restarting" | "succeeded";

const attemptStorageKey = "dala:update-attempt";
const pollIntervalMs = 1_000;
const statusRequestTimeoutMs = 10_000;
const applyFailureGraceMs = 10_000;
const updateTimeoutMs = 15 * 60 * 1_000;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const tagPattern = /^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

function createAttemptId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID().toLowerCase();

  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function readStoredAttempt(): StoredAttempt | null {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(attemptStorageKey) ?? "null");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid attempt");

    const value = parsed as Record<string, unknown>;
    const keys = Object.keys(value).sort().join(",");
    if (keys !== "attemptId,requestedAt,target") throw new Error("invalid attempt");
    if (typeof value.attemptId !== "string" || !uuidPattern.test(value.attemptId)) {
      throw new Error("invalid attempt");
    }
    if (typeof value.target !== "string" || !tagPattern.test(value.target)) throw new Error("invalid attempt");
    if (typeof value.requestedAt !== "string") throw new Error("invalid attempt");

    const requestedAt = Date.parse(value.requestedAt);
    const age = Date.now() - requestedAt;
    if (!Number.isFinite(requestedAt) || age < -30_000 || age > updateTimeoutMs) {
      throw new Error("expired attempt");
    }

    return {
      attemptId: value.attemptId,
      target: value.target,
      requestedAt: value.requestedAt,
    };
  } catch {
    try {
      localStorage.removeItem(attemptStorageKey);
    } catch {
      // Ignore unavailable browser storage.
    }
    return null;
  }
}

function writeStoredAttempt(attempt: StoredAttempt): void {
  try {
    localStorage.setItem(attemptStorageKey, JSON.stringify(attempt));
  } catch {
    // Updating still works when browser storage is unavailable; only reload recovery is lost.
  }
}

function clearStoredAttempt(expectedAttemptId: string): void {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(attemptStorageKey) ?? "null");
    if (
      parsed &&
      typeof parsed === "object" &&
      !Array.isArray(parsed) &&
      (parsed as Record<string, unknown>).attemptId === expectedAttemptId
    ) {
      localStorage.removeItem(attemptStorageKey);
    }
  } catch {
    // Leave malformed or concurrently replaced data to readStoredAttempt.
  }
}

/**
 * Sidebar-footer self-upgrade. Windows activation runs in a detached helper,
 * so scheduling and completion are deliberately separate: this component
 * persists a client-generated attempt id before applying and trusts only that
 * correlated final result, including after a daemon reconnect.
 */
export default function UpdateCheck() {
  const { t } = useI18n();
  const [info, setInfo] = useState<Info | null>(null);
  const [attempt, setAttempt] = useState<StoredAttempt | null>(() => readStoredAttempt());
  const [state, setState] = useState<UpdateState>(() => attempt ? "restarting" : "idle");
  const [error, setError] = useState<string | null>(null);
  const activeAttemptId = useRef<string | null>(attempt?.attemptId ?? null);
  const pollNow = useRef<() => void>(() => undefined);
  const applyError = useRef<string | null>(null);
  const applyFailedAt = useRef<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const result = await call<Info>(checkUpdate, {
        fields: ["enabled", "current", "latest", "tag", "updateAvailable", "notesUrl", "legacyEnvConfig"],
      });
      if (!cancelled && result.ok) setInfo(result.data);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => onReconnect(() => pollNow.current()), []);

  useEffect(() => {
    if (!attempt) {
      pollNow.current = () => undefined;
      return;
    }

    let cancelled = false;
    let inFlight = false;
    let timer: number | null = null;
    let activeController: AbortController | null = null;

    const stopPolling = () => {
      cancelled = true;
      pollNow.current = () => undefined;
      activeController?.abort();
      activeController = null;
      if (timer !== null) {
        window.clearInterval(timer);
        timer = null;
      }
    };

    const fail = (message: string) => {
      stopPolling();
      clearStoredAttempt(attempt.attemptId);
      applyError.current = null;
      applyFailedAt.current = null;
      activeAttemptId.current = null;
      setAttempt(null);
      setState("idle");
      setError(message || t("somethingWentWrong"));
    };

    const poll = async () => {
      if (inFlight || cancelled) return;

      const age = Date.now() - Date.parse(attempt.requestedAt);
      if (!Number.isFinite(age) || age > updateTimeoutMs) {
        fail(applyError.current || t("somethingWentWrong"));
        return;
      }

      inFlight = true;
      const controller = new AbortController();
      activeController = controller;
      let requestTimeout: number | null = null;
      const result = await Promise.race([
        call<StatusResult>(updateStatus, {
          input: { attemptId: attempt.attemptId },
          fields: ["attemptId", "status", "target", "message", "rolledBack"],
          fetchOptions: { signal: controller.signal },
        }),
        new Promise<null>((resolve) => {
          requestTimeout = window.setTimeout(() => {
            controller.abort();
            resolve(null);
          }, statusRequestTimeoutMs);
        }),
      ]);
      if (requestTimeout !== null) window.clearTimeout(requestTimeout);
      if (activeController === controller) activeController = null;
      inFlight = false;
      if (cancelled || result === null) return;

      if (!result.ok) return;

      const updateResult = result.data;
      if (updateResult.attemptId !== attempt.attemptId) return;
      if (updateResult.target && updateResult.target !== attempt.target) return;

      switch (updateResult.status) {
        case "pending":
          applyError.current = null;
          applyFailedAt.current = null;
          setState("restarting");
          setError(null);
          break;
        case "succeeded":
          stopPolling();
          setState("succeeded");
          setError(null);
          break;
        case "failed":
          fail(updateResult.message || t("somethingWentWrong"));
          break;
        case "unknown":
          if (
            applyError.current &&
            applyFailedAt.current !== null &&
            Date.now() - applyFailedAt.current >= applyFailureGraceMs
          ) {
            fail(applyError.current);
          }
          break;
      }
    };

    pollNow.current = () => void poll();
    void poll();
    if (!cancelled) timer = window.setInterval(() => void poll(), pollIntervalMs);

    return () => {
      stopPolling();
    };
  }, [attempt, t]);

  // The page meta always knows the running server version, so the footer
  // shows it even before (or without) the update check answering.
  const current = info?.current ?? serverVersion;
  if (!current) return null;

  const available = Boolean(info && info.enabled && info.updateAvailable && info.latest);

  const update = async () => {
    const target = info?.tag;
    if (!target || !tagPattern.test(target)) return;

    const attemptId = createAttemptId();
    if (!uuidPattern.test(attemptId)) {
      setError(t("somethingWentWrong"));
      return;
    }

    const intent: StoredAttempt = {
      attemptId,
      target,
      requestedAt: new Date().toISOString(),
    };
    writeStoredAttempt(intent);
    activeAttemptId.current = attemptId;
    setAttempt(intent);
    setState("updating");
    setError(null);
    applyError.current = null;
    applyFailedAt.current = null;

    const result = await call<ApplyResult>(applyUpdate, {
      input: { attemptId, expectedTarget: target },
      fields: ["attemptId", "status", "updatedTo"],
    });

    if (activeAttemptId.current !== attemptId) return;

    if (!result.ok) {
      applyError.current = result.error || t("somethingWentWrong");
      applyFailedAt.current = Date.now();
      setState((currentState) => currentState === "updating" ? "restarting" : currentState);
      return;
    }

    if (result.data.attemptId !== attemptId || result.data.updatedTo !== target) {
      clearStoredAttempt(attemptId);
      applyFailedAt.current = null;
      activeAttemptId.current = null;
      setAttempt(null);
      setState("idle");
      setError(t("somethingWentWrong"));
      return;
    }

    setState((currentState) => currentState === "updating" ? "restarting" : currentState);
  };

  const reload = () => {
    if (attempt) clearStoredAttempt(attempt.attemptId);
    location.reload();
  };

  return (
    <div id="update-check" className="space-y-1">
      <div className="flex items-center justify-between gap-2">
        <span id="server-version" className="font-mono text-[11px] text-fg-muted/70" title={t("version")}>
          v{current}
        </span>
        {available && state === "idle" && (
          <button
            id="update-now-button"
            onClick={() => void update()}
            className="shrink-0 rounded border border-mint/50 px-1.5 py-0.5 font-mono text-[11px] text-mint transition-colors hover:bg-mint/10"
          >
            {t("updateTo", { version: `v${info?.latest}` })}
          </button>
        )}
        {state === "updating" && (
          <span className="font-mono text-[11px] text-mint">{t("updating")}</span>
        )}
      </div>
      {state === "restarting" && (
        <div id="update-restarting" className="font-mono text-[11px] text-mint">
          {t("updateReload")}
        </div>
      )}
      {state === "succeeded" && (
        <button
          id="update-reload-button"
          type="button"
          onClick={reload}
          className="font-mono text-[11px] text-mint underline decoration-dotted underline-offset-2 hover:brightness-110"
        >
          {t("serverUpdatedReload")}
        </button>
      )}
      {info?.legacyEnvConfig && (
        <a
          id="config-migrate-notice"
          href="https://github.com/mjason/dala/blob/main/docs/config-migration.md"
          target="_blank"
          rel="noreferrer"
          className="block text-[11px] leading-4 text-[#d9a860] underline decoration-dotted underline-offset-2 hover:brightness-110"
        >
          {t("configMigrateNotice")}
        </a>
      )}
      {error && <div className="text-[11px] text-danger">{error}</div>}
    </div>
  );
}
