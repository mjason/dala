import React, { useEffect, useState } from "react";
import Windowed from "./Windowed";
import { useI18n } from "./i18n";
import { lspServers } from "../ash_rpc";
import { call } from "./rpc";

type RecentMessage = { dir: "in" | "out"; at: number; preview: string };

type BridgeEntry = {
  id: number;
  root: string;
  path: string;
  name: string;
  command: string;
  status: "running" | "exited";
  exit_status: number | null;
  started_at: number;
  last_activity: number;
  in_count: number;
  out_count: number;
  recent: RecentMessage[];
  diagnostics: {
    uri: string;
    count: number;
    items: { message: string; severity: number | null; line: number | null }[];
  } | null;
  stderr_tail: string | null;
};

const SEVERITY = ["", "error", "warning", "info", "hint"];

function age(since: number) {
  const seconds = Math.max(0, Math.round((Date.now() - since) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h${Math.floor((seconds % 3600) / 60)}m`;
}

/**
 * The LSP debug window: every bridge connection with its health, traffic,
 * current diagnostics, recent JSON-RPC messages and the server's stderr.
 * The same data is served as JSON at /lsp/debug, so AI agents running in a
 * terminal can `curl` it — the footer spells the command out.
 */
export default function LspDebug({ path, onClose }: { path: string; onClose: () => void }) {
  const { t } = useI18n();
  const [servers, setServers] = useState<BridgeEntry[] | null>(null);
  const [resolved, setResolved] = useState<{
    language: string | null;
    names: string[];
    checked: { path: string; found: boolean }[];
  } | null>(null);

  // What discovery decides for THIS file — shown even before (or without)
  // any connection, so an empty registry explains itself.
  useEffect(() => {
    let disposed = false;
    void (async () => {
      const result = await call<{
        language: string | null;
        servers: { name: string }[];
        checked: { path: string; found: boolean }[];
      }>(lspServers, { input: { path }, fields: ["root", "language", "servers", "checked"] as never });
      if (disposed || !result.ok) return;
      const data = result.data;
      setResolved({
        language: data.language,
        names: data.servers.map((s) => s.name),
        checked: data.checked ?? [],
      });
    })();
    return () => {
      disposed = true;
    };
  }, [path]);

  useEffect(() => {
    let disposed = false;
    const load = async () => {
      try {
        const response = await fetch("/lsp/debug", { credentials: "same-origin" });
        if (!response.ok) return;
        const body = (await response.json()) as { servers: BridgeEntry[] };
        if (!disposed) setServers(body.servers);
      } catch {
        // transient — next poll retries
      }
    };
    void load();
    const timer = window.setInterval(() => void load(), 2000);
    return () => {
      disposed = true;
      window.clearInterval(timer);
    };
  }, []);

  const list = [...(servers ?? [])].sort((a, b) => {
    const aMine = a.path === path ? 0 : 1;
    const bMine = b.path === path ? 0 : 1;
    return aMine - bMine || b.started_at - a.started_at;
  });

  const debugUrl = `${window.location.origin}/lsp/debug`;

  return (
    <Windowed id="lsp-debug" onClose={onClose} title={t("lspDebugTitle")}>
      <div className="flex h-full flex-col gap-3 overflow-y-auto p-4 font-mono text-xs">
        {resolved && (
          <div className="rounded-lg border border-line/70 bg-bg0 p-3 text-fg-muted">
            <span className="text-fg">{path.split("/").pop()}</span>
            {" · "}
            {resolved.language === null
              ? t("lspNoLanguage")
              : resolved.names.length === 0
                ? t("lspNoInstalledServers", { language: resolved.language })
                : `${resolved.language} → ${resolved.names.join(" + ")}`}
            {resolved.checked.length > 0 && (
              <details className="mt-2" open={resolved.names.length === 0}>
                <summary className="cursor-pointer">{t("lspProbedPaths")}</summary>
                <div className="mt-1 space-y-0.5">
                  {resolved.checked.map((candidate, i) => (
                    <div key={i} className="truncate">
                      <span className={candidate.found ? "text-mint" : "text-fg-muted/60"}>
                        {candidate.found ? "✓" : "✗"}
                      </span>{" "}
                      {candidate.path}
                    </div>
                  ))}
                </div>
              </details>
            )}
          </div>
        )}
        {servers === null ? (
          <div className="text-fg-muted">…</div>
        ) : list.length === 0 ? (
          <div className="text-fg-muted">{t("lspNoServers")}</div>
        ) : (
          list.map((entry) => (
            <div
              key={entry.id}
              className={[
                "rounded-lg border border-line bg-bg0 p-3",
                entry.path === path ? "border-mint/40" : "",
              ].join(" ")}
            >
              <div className="flex flex-wrap items-center gap-2">
                <span
                  className={[
                    "inline-block h-2 w-2 rounded-full",
                    entry.status === "running" ? "bg-mint" : "bg-red-400",
                  ].join(" ")}
                />
                <span className="font-semibold text-fg">{entry.name}</span>
                <span className="text-fg-muted">
                  {entry.status === "running"
                    ? `${t("lspRunning")} · ${age(entry.started_at)}`
                    : `${t("lspExited")}${entry.exit_status != null ? ` (${entry.exit_status})` : ""}`}
                </span>
                <span className="text-fg-muted">
                  ↑{entry.in_count} ↓{entry.out_count}
                </span>
                <span className="ml-auto truncate text-fg-muted" title={entry.path}>
                  {entry.path.split("/").pop()}
                </span>
              </div>
              <div className="mt-1 truncate text-fg-muted" title={entry.command}>
                {entry.command}
              </div>

              {entry.diagnostics && (
                <div className="mt-2">
                  <div className="text-fg-muted">
                    {t("lspDiagnostics", { count: entry.diagnostics.count })}
                  </div>
                  {entry.diagnostics.items.slice(0, 8).map((item, i) => (
                    <div key={i} className="truncate">
                      <span
                        className={
                          item.severity === 1
                            ? "text-red-400"
                            : item.severity === 2
                              ? "text-amber-400"
                              : "text-fg-muted"
                        }
                      >
                        {SEVERITY[item.severity ?? 3]}
                      </span>{" "}
                      <span className="text-fg-muted">L{(item.line ?? 0) + 1}</span>{" "}
                      {item.message}
                    </div>
                  ))}
                </div>
              )}

              {entry.recent.length > 0 && (
                <details className="mt-2">
                  <summary className="cursor-pointer text-fg-muted">
                    {t("lspRecent", { count: entry.recent.length })}
                  </summary>
                  <div className="mt-1 max-h-48 overflow-y-auto rounded bg-bg1 p-2">
                    {entry.recent.map((message, i) => (
                      <div key={i} className="truncate">
                        <span className={message.dir === "in" ? "text-mint" : "text-sky-400"}>
                          {message.dir === "in" ? "→" : "←"}
                        </span>{" "}
                        {message.preview}
                      </div>
                    ))}
                  </div>
                </details>
              )}

              {entry.stderr_tail && (
                <details className="mt-2" open={entry.status === "exited"}>
                  <summary className="cursor-pointer text-fg-muted">stderr</summary>
                  <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-bg1 p-2 text-amber-200/80">
                    {entry.stderr_tail}
                  </pre>
                </details>
              )}
            </div>
          ))
        )}

        <div className="mt-auto rounded-md border border-line/60 p-2 text-fg-muted">
          {t("lspAiHint")}
          <code className="ml-1 select-all text-fg">curl {debugUrl}</code>
        </div>
      </div>
    </Windowed>
  );
}
