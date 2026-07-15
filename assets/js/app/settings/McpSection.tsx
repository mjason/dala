import React, { useState } from "react";
import { FieldLabel } from "../ui";
import { useI18n } from "../i18n";
import { writeClipboard } from "../util";

/**
 * MCP connection panel. dala ships an MCP server (POST /mcp, gated by
 * DALA_MCP_ENABLED + DALA_MCP_TOKEN) that lets an AI assistant read and write
 * the user's server-side settings (chiefly defining themes). This panel shows
 * the LIVE endpoint (window.location.origin + "/mcp") and copy-ready connect
 * snippets for Claude Code, Codex and OpenCode.
 *
 * The browser is NEVER given the real token: every snippet carries a localized
 * placeholder (mcpTokenPlaceholder). The config snippets themselves stay
 * technical/untranslated — only labels, notes and prompts are localized.
 */

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

export default function McpSection() {
  const { t } = useI18n();

  // The LIVE endpoint — whatever origin this page is served from. Never a
  // hardcoded host: a LAN peer opening the app sees the address they can reach.
  const url = `${window.location.origin}/mcp`;
  // Localized placeholder; the real DALA_MCP_TOKEN is set server-side and is
  // deliberately NOT available to the browser.
  const token = t("mcpTokenPlaceholder");

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
      <div data-mcp-client="codex" className="space-y-2 rounded-lg border border-line/70 p-3">
        <div className="text-[13px] font-medium text-fg">{t("mcpCodexTitle")}</div>
        <Snippet text={codexToml} caption="~/.codex/config.toml" />
        <p className="text-[12px] leading-relaxed text-fg-muted">{t("mcpCodexNote")}</p>
      </div>

      {/* OpenCode */}
      <div data-mcp-client="opencode" className="space-y-2 rounded-lg border border-line/70 p-3">
        <div className="text-[13px] font-medium text-fg">{t("mcpOpencodeTitle")}</div>
        <Snippet text={opencodeJson} caption="opencode.json" />
        <p className="text-[12px] leading-relaxed text-fg-muted">{t("mcpOpencodeNote")}</p>
      </div>

      {/* stdio-only fallback */}
      <div className="space-y-1.5">
        <p className="text-[12px] leading-relaxed text-fg-muted">{t("mcpRemoteFallback")}</p>
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
    </div>
  );
}
