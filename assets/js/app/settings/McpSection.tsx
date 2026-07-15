import React, { useEffect, useRef, useState } from "react";
import { mcpSettings, regenerateMcpToken, setMcpEnabled } from "../../ash_rpc";
import { call } from "../rpc";
import { FieldLabel, Toggle } from "../ui";
import { useI18n } from "../i18n";
import { writeClipboard } from "../util";

/**
 * MCP live control. dala ships an MCP server (POST /mcp) that lets an AI
 * assistant read and write the user's server-side settings (chiefly defining
 * themes). Enablement and the bearer token now live in the DB
 * (Dala.Settings.Mcp, a global singleton) and are driven from HERE at runtime:
 *
 *   - `mcpSettings`       → load { enabled, token } (auto-provisions a token).
 *   - `setMcpEnabled`     → flip the runtime gate; /mcp 404s the moment it's off.
 *   - `regenerateMcpToken`→ mint a fresh token; the old one dies server-side.
 *
 * When enabled, the panel shows the LIVE endpoint (window.location.origin +
 * "/mcp"), the REAL token (copyable + regenerate), and copy-ready connect
 * snippets for Claude Code, Codex and OpenCode with the token already baked
 * into the Bearer header. The config snippets stay technical/untranslated —
 * only labels, notes and prompts are localized.
 */

type McpConfig = { enabled: boolean; token: string };

/** Copy button with a transient "copied" state. writeClipboard degrades
 * gracefully when navigator.clipboard is unavailable (plain-http LAN origins
 * fall back to a scratch textarea), so the guard is centralized there. */
function CopyButton({ text, className }: { text: string; className?: string }) {
  const { t } = useI18n();
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    const ok = await writeClipboard(text);
    if (!ok) return;
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1500);
  };

  return (
    <button
      type="button"
      data-mcp-copy
      aria-label={t("mcpCopy")}
      onClick={() => void copy()}
      className={`shrink-0 rounded-md border px-2 py-1 text-[11px] transition-colors ${
        copied
          ? "border-mint/60 text-mint"
          : "border-line text-fg-muted hover:border-mint/60 hover:text-mint"
      } ${className ?? ""}`}
    >
      {copied ? t("mcpCopied") : t("mcpCopy")}
    </button>
  );
}

/** A monospace config/command block with a copy button and an optional caption
 * (e.g. the config file path — technical, kept literal, not translated). */
function Snippet({ text, caption }: { text: string; caption?: string }) {
  return (
    <div className="space-y-1">
      {caption && <div className="font-mono text-[11px] text-fg-muted">{caption}</div>}
      <div className="relative">
        <pre className="overflow-x-auto rounded-md border border-line bg-bg0 py-2 pr-14 pl-3 font-mono text-[12px] leading-relaxed text-fg">
          {text}
        </pre>
        <CopyButton text={text} className="absolute top-1.5 right-1.5" />
      </div>
    </div>
  );
}

export default function McpSection({ onError }: { onError: (message: string) => void }) {
  const { t } = useI18n();

  // null = still loading the server-side singleton on mount.
  const [config, setConfig] = useState<McpConfig | null>(null);
  const [busy, setBusy] = useState(false);
  const [regenerated, setRegenerated] = useState(false);

  // Keep the latest onError without re-running the mount effect: the parent
  // hands a fresh closure every render (mirrors useThemeLibrary).
  const onErrorRef = useRef(onError);
  onErrorRef.current = onError;

  const normalize = (data: { enabled?: boolean | null; token?: string | null }): McpConfig => ({
    enabled: data.enabled === true,
    token: data.token ?? "",
  });

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const result = await call<McpConfig>(mcpSettings, { fields: ["enabled", "token"] });
      if (cancelled) return;
      if (result.ok) setConfig(normalize(result.data));
      else onErrorRef.current(result.error);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const toggle = async (enabled: boolean) => {
    setBusy(true);
    const result = await call<McpConfig>(setMcpEnabled, {
      input: { enabled },
      fields: ["enabled", "token"],
    });
    setBusy(false);
    if (result.ok) setConfig(normalize(result.data));
    else onErrorRef.current(result.error);
  };

  const regenerate = async () => {
    setBusy(true);
    const result = await call<{ token: string | null }>(regenerateMcpToken, {
      fields: ["token"],
    });
    setBusy(false);
    if (!result.ok) {
      onErrorRef.current(result.error);
      return;
    }
    setConfig((prev) => (prev ? { ...prev, token: result.data.token ?? "" } : prev));
    setRegenerated(true);
    window.setTimeout(() => setRegenerated(false), 1500);
  };

  // The LIVE endpoint — whatever origin this page is served from. Never a
  // hardcoded host: a LAN peer opening the app sees the address they can reach.
  const url = `${window.location.origin}/mcp`;
  const token = config?.token ?? "";

  // Real token baked straight into every snippet's Bearer header, so each block
  // is copy-and-paste ready — no placeholder to hand-edit.
  const claudeCli =
    `claude mcp add --transport http dala ${url} \\\n` +
    `  --header "Authorization: Bearer ${token}"`;

  const claudeJson =
    `{ "mcpServers": { "dala": {\n` +
    `  "type": "http",\n` +
    `  "url": "${url}",\n` +
    `  "headers": { "Authorization": "Bearer ${token}" }\n` +
    `}}}`;

  const codexToml =
    `[mcp_servers.dala]\n` +
    `url = "${url}"\n` +
    `http_headers = { "Authorization" = "Bearer ${token}" }`;

  const opencodeJson =
    `{ "$schema": "https://opencode.ai/config.json",\n` +
    `  "mcp": { "dala": {\n` +
    `    "type": "remote",\n` +
    `    "url": "${url}",\n` +
    `    "enabled": true,\n` +
    `    "headers": { "Authorization": "Bearer ${token}" }\n` +
    `  }}}`;

  const mcpRemote = `npx -y mcp-remote ${url} --header "Authorization: Bearer ${token}"`;

  const examples = [t("mcpExample1"), t("mcpExample2"), t("mcpExample3")];

  return (
    <div className="space-y-4">
      <div>
        <div className="text-[13px] font-medium text-fg">{t("mcpHeading")}</div>
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">{t("mcpIntro")}</p>
      </div>

      {config === null ? (
        <p className="text-[12px] leading-relaxed text-fg-muted">{t("loading")}</p>
      ) : (
        <>
          {/* Runtime enable toggle. The Toggle primitive is used directly (not
              ToggleRow) so the async setMcpEnabled handler fires exactly once
              per click — ToggleRow's label+button pair double-invokes onChange,
              which is idempotent for a sync setter but would double-post here. */}
          <div className="space-y-1.5">
            <div className="flex items-center justify-between gap-3 rounded-lg border border-line/70 px-3 py-2">
              <span className="text-[13px] text-fg">{t("mcpEnableLabel")}</span>
              <Toggle
                id="mcp-enabled-toggle"
                checked={config.enabled}
                onChange={(v) => void toggle(v)}
              />
            </div>
            <p className="text-[12px] leading-relaxed text-fg-muted">{t("mcpEnableHint")}</p>
          </div>

          {config.enabled ? (
            <>
              {/* Address */}
              <div className="space-y-1.5">
                <FieldLabel>{t("mcpAddressLabel")}</FieldLabel>
                <div className="flex items-center gap-2">
                  <code
                    id="mcp-endpoint-url"
                    className="min-w-0 flex-1 overflow-x-auto rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[13px] whitespace-nowrap text-fg"
                  >
                    {url}
                  </code>
                  <CopyButton text={url} />
                </div>
                <p className="text-[12px] leading-relaxed text-fg-muted">{t("mcpTokenNote")}</p>
              </div>

              {/* Token */}
              <div className="space-y-1.5">
                <FieldLabel>{t("mcpTokenLabel")}</FieldLabel>
                <div className="flex items-center gap-2">
                  <code
                    id="mcp-token"
                    className="min-w-0 flex-1 overflow-x-auto rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[13px] whitespace-nowrap text-fg"
                  >
                    {token}
                  </code>
                  <CopyButton text={token} />
                  <button
                    id="mcp-regenerate-token"
                    type="button"
                    onClick={() => void regenerate()}
                    disabled={busy}
                    className={`shrink-0 rounded-md border px-2 py-1 text-[11px] transition-colors disabled:opacity-50 ${
                      regenerated
                        ? "border-mint/60 text-mint"
                        : "border-line text-fg-muted hover:border-danger/60 hover:text-danger"
                    }`}
                  >
                    {regenerated ? t("mcpRegenerated") : t("mcpRegenerate")}
                  </button>
                </div>
                <p className="text-[12px] leading-relaxed text-fg-muted">
                  {t("mcpTokenSecurityNote")}
                </p>
              </div>

              {/* Claude Code */}
              <div
                data-mcp-client="claude-code"
                className="space-y-2 rounded-lg border border-line/70 p-3"
              >
                <div className="text-[13px] font-medium text-fg">{t("mcpClaudeCodeTitle")}</div>
                <Snippet text={claudeCli} />
                <Snippet text={claudeJson} caption=".mcp.json" />
              </div>

              {/* Codex */}
              <div
                data-mcp-client="codex"
                className="space-y-2 rounded-lg border border-line/70 p-3"
              >
                <div className="text-[13px] font-medium text-fg">{t("mcpCodexTitle")}</div>
                <Snippet text={codexToml} caption="~/.codex/config.toml" />
                <p className="text-[12px] leading-relaxed text-fg-muted">{t("mcpCodexNote")}</p>
              </div>

              {/* OpenCode */}
              <div
                data-mcp-client="opencode"
                className="space-y-2 rounded-lg border border-line/70 p-3"
              >
                <div className="text-[13px] font-medium text-fg">{t("mcpOpencodeTitle")}</div>
                <Snippet text={opencodeJson} caption="opencode.json" />
                <p className="text-[12px] leading-relaxed text-fg-muted">{t("mcpOpencodeNote")}</p>
              </div>

              {/* stdio-only fallback */}
              <div className="space-y-1.5">
                <p className="text-[12px] leading-relaxed text-fg-muted">
                  {t("mcpRemoteFallback")}
                </p>
                <Snippet text={mcpRemote} />
              </div>

              {/* Example prompts */}
              <div className="space-y-1.5">
                <FieldLabel>{t("mcpExamplePromptsLabel")}</FieldLabel>
                <ul className="space-y-1.5">
                  {examples.map((prompt, i) => (
                    <li
                      key={i}
                      className="rounded-md border border-line/70 bg-bg2 px-2.5 py-1.5 text-[12px] leading-relaxed text-fg"
                    >
                      {prompt}
                    </li>
                  ))}
                </ul>
              </div>
            </>
          ) : (
            <p className="text-[12px] leading-relaxed text-fg-muted/80">{t("mcpDisabledHint")}</p>
          )}
        </>
      )}
    </div>
  );
}
