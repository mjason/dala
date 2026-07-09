import React, { useEffect, useState } from "react";
import { applyUpdate, buildCSRFHeaders, checkUpdate } from "../ash_rpc";
import { useI18n } from "./i18n";

type Info = {
  enabled: boolean | null;
  current: string;
  latest: string | null;
  tag: string | null;
  updateAvailable: boolean | null;
  notesUrl: string | null;
};

/**
 * Sidebar-footer self-upgrade: checks GitHub for a newer release once per
 * page load; when one exists (installed releases only) offers a one-click
 * upgrade. The daemon swaps its `current` symlink and restarts — shells
 * survive inside their PTY holders — then the page reloads itself.
 */
export default function UpdateCheck() {
  const { t } = useI18n();
  const [info, setInfo] = useState<Info | null>(null);
  const [state, setState] = useState<"idle" | "updating" | "restarting">("idle");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const result = await checkUpdate({
        fields: ["enabled", "current", "latest", "tag", "updateAvailable", "notesUrl"],
        headers: buildCSRFHeaders(),
      }).catch(() => null);
      if (!cancelled && result?.success) setInfo(result.data as unknown as Info);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (!info) return null;

  const available = Boolean(info.enabled && info.updateAvailable && info.latest);

  const update = async () => {
    setState("updating");
    setError(null);
    const result = await applyUpdate({ fields: ["updatedTo"], headers: buildCSRFHeaders() });
    if (!result.success) {
      setState("idle");
      setError(result.errors[0]?.message ?? t("somethingWentWrong"));
      return;
    }

    // The daemon restarts underneath us; reload once it answers again.
    setState("restarting");
    await new Promise((resolve) => setTimeout(resolve, 3000));
    for (let i = 0; i < 120; i++) {
      try {
        const response = await fetch("/", { cache: "no-store" });
        if (response.ok) break;
      } catch {
        // still down
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    location.reload();
  };

  return (
    <div id="update-check" className="space-y-1">
      <div className="flex items-center justify-between gap-2">
        <span className="font-mono text-[11px] text-fg-muted/70" title={t("version")}>
          v{info.current}
        </span>
        {available && state === "idle" && (
          <button
            id="update-now-button"
            onClick={() => void update()}
            className="shrink-0 rounded border border-mint/50 px-1.5 py-0.5 font-mono text-[11px] text-mint transition-colors hover:bg-mint/10"
          >
            {t("updateTo", { version: `v${info.latest}` })}
          </button>
        )}
        {state === "updating" && (
          <span className="font-mono text-[11px] text-mint">{t("updating")}</span>
        )}
      </div>
      {state === "restarting" && (
        <div className="font-mono text-[11px] text-mint">{t("updateReload")}</div>
      )}
      {error && <div className="text-[11px] text-danger">{error}</div>}
    </div>
  );
}
