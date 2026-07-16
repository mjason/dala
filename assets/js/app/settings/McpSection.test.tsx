import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { I18nProvider } from "../i18n";

// The clipboard helper degrades gracefully in prod; here we just watch it.
const writeClipboard = vi.fn().mockResolvedValue(true);
vi.mock("../util", () => ({
  writeClipboard: (...a: unknown[]) => writeClipboard(...a),
}));

// The three MCP actions are spied; `call` (../rpc) wraps them and reads
// `result.success`/`result.data`, so each mock returns that shape.
const mcpSettings = vi.fn();
const setMcpEnabled = vi.fn();
const setMcpTerminalAccess = vi.fn();
const regenerateMcpToken = vi.fn();
vi.mock("../../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  mcpSettings: (...a: unknown[]) => mcpSettings(...a),
  setMcpEnabled: (...a: unknown[]) => setMcpEnabled(...a),
  setMcpTerminalAccess: (...a: unknown[]) => setMcpTerminalAccess(...a),
  regenerateMcpToken: (...a: unknown[]) => regenerateMcpToken(...a),
}));

import McpSection from "./McpSection";

const ORIGIN = window.location.origin;
const ENDPOINT = `${ORIGIN}/mcp`;
const TOKEN = "tok_live_abcdef123456";

function renderSection() {
  const onError = vi.fn();
  const utils = render(
    <I18nProvider>
      <McpSection onError={onError} />
    </I18nProvider>,
  );
  return { ...utils, onError };
}

const q = (c: HTMLElement, sel: string) => c.querySelector(sel) as HTMLElement;
// The enable switch: id lives on the hidden checkbox; the clickable control is
// the role="switch" ancestor.
const toggleButton = (c: HTMLElement) =>
  q(c, "#mcp-enabled-toggle").closest('[role="switch"]') as HTMLElement;

beforeEach(() => {
  writeClipboard.mockClear();
  mcpSettings.mockReset();
  setMcpEnabled.mockReset();
  setMcpTerminalAccess.mockReset();
  regenerateMcpToken.mockReset();
  mcpSettings.mockResolvedValue({
    success: true,
    data: { enabled: true, token: TOKEN, terminalRead: false, terminalControl: false },
  });
  setMcpEnabled.mockResolvedValue({
    success: true,
    data: { enabled: true, token: TOKEN, terminalRead: false, terminalControl: false },
  });
  setMcpTerminalAccess.mockResolvedValue({
    success: true,
    data: { enabled: true, token: TOKEN, terminalRead: true, terminalControl: true },
  });
  regenerateMcpToken.mockResolvedValue({ success: true, data: { token: TOKEN } });
});
afterEach(cleanup);

describe("McpSection live control", () => {
  it("loads the config on mount and reflects the enabled state", async () => {
    const { container } = renderSection();
    await waitFor(() => expect(q(container, "#mcp-enabled-toggle")).not.toBeNull());
    expect(mcpSettings).toHaveBeenCalledTimes(1);
    expect((q(container, "#mcp-enabled-toggle") as HTMLInputElement).checked).toBe(true);
  });

  it("shows the endpoint and the REAL token when enabled", async () => {
    const { container } = renderSection();
    await waitFor(() => expect(q(container, "#mcp-endpoint-url")).not.toBeNull());
    expect(q(container, "#mcp-endpoint-url").textContent).toBe(ENDPOINT);
    expect(q(container, "#mcp-token").textContent).toBe(TOKEN);
  });

  it("keeps terminal read/control as explicit opt-in permissions", async () => {
    const { container } = renderSection();
    await waitFor(() => expect(q(container, "#mcp-terminal-control-toggle")).not.toBeNull());

    expect((q(container, "#mcp-terminal-read-toggle") as HTMLInputElement).checked).toBe(false);
    expect((q(container, "#mcp-terminal-control-toggle") as HTMLInputElement).checked).toBe(false);

    const control = q(container, "#mcp-terminal-control-toggle").closest(
      '[role="switch"]',
    ) as HTMLElement;
    fireEvent.click(control);

    await waitFor(() => expect(setMcpTerminalAccess).toHaveBeenCalledTimes(1));
    expect(setMcpTerminalAccess.mock.calls[0][0].input).toEqual({
      terminalRead: true,
      terminalControl: true,
    });
  });

  it("bakes the real token (not a placeholder) into every client snippet", async () => {
    const { container } = renderSection();
    await waitFor(() => expect(q(container, '[data-mcp-client="claude-code"]')).not.toBeNull());
    for (const client of ["claude-code", "codex", "opencode"]) {
      const text = q(container, `[data-mcp-client="${client}"]`).textContent ?? "";
      expect(text).toContain(ENDPOINT);
      expect(text).toContain(`Bearer ${TOKEN}`);
      expect(text).not.toContain("DALA_MCP_TOKEN");
    }
  });

  it("keeps the source-verified per-client flags", async () => {
    const { container } = renderSection();
    await waitFor(() => expect(q(container, '[data-mcp-client="codex"]')).not.toBeNull());
    expect(q(container, '[data-mcp-client="claude-code"]').textContent).toContain(
      "claude mcp add --transport http dala",
    );
    const codex = q(container, '[data-mcp-client="codex"]').textContent ?? "";
    expect(codex).toContain("[mcp_servers.dala]");
    expect(codex).toContain("http_headers");
    expect(q(container, '[data-mcp-client="opencode"]').textContent).toContain('"type": "remote"');
  });

  it("copy button writes the ready-to-paste snippet (with the real token)", async () => {
    const { container } = renderSection();
    await waitFor(() => expect(q(container, '[data-mcp-client="claude-code"]')).not.toBeNull());
    const copyBtn = q(container, '[data-mcp-client="claude-code"] [data-mcp-copy]');
    fireEvent.click(copyBtn);
    expect(writeClipboard).toHaveBeenCalledTimes(1);
    const arg = writeClipboard.mock.calls[0][0] as string;
    expect(arg).toContain(ENDPOINT);
    expect(arg).toContain(`Bearer ${TOKEN}`);
  });

  it("lists example prompts that each invoke the dala MCP", async () => {
    const { container } = renderSection();
    await waitFor(() => expect(container.querySelectorAll("li").length).toBeGreaterThanOrEqual(3));
    for (const li of Array.from(container.querySelectorAll("li"))) {
      expect(li.textContent ?? "").toContain("dala MCP");
    }
  });

  it("toggling off calls setMcpEnabled and hides the token + snippets", async () => {
    setMcpEnabled.mockResolvedValue({ success: true, data: { enabled: false, token: TOKEN } });
    const { container } = renderSection();
    await waitFor(() => expect(q(container, "#mcp-token")).not.toBeNull());

    fireEvent.click(toggleButton(container));

    await waitFor(() => expect(container.querySelector("#mcp-token")).toBeNull());
    expect(setMcpEnabled).toHaveBeenCalledTimes(1);
    expect(setMcpEnabled.mock.calls[0][0].input).toEqual({ enabled: false });
    expect((q(container, "#mcp-enabled-toggle") as HTMLInputElement).checked).toBe(false);
    expect(container.querySelector('[data-mcp-client="claude-code"]')).toBeNull();
    expect(container.querySelector("#mcp-endpoint-url")).toBeNull();
  });

  it("toggling on from a disabled start reveals the connection details", async () => {
    mcpSettings.mockResolvedValue({ success: true, data: { enabled: false, token: TOKEN } });
    setMcpEnabled.mockResolvedValue({ success: true, data: { enabled: true, token: TOKEN } });
    const { container } = renderSection();
    await waitFor(() => expect(q(container, "#mcp-enabled-toggle")).not.toBeNull());
    expect(container.querySelector("#mcp-token")).toBeNull();

    fireEvent.click(toggleButton(container));

    await waitFor(() => expect(q(container, "#mcp-token")).not.toBeNull());
    expect(setMcpEnabled.mock.calls[0][0].input).toEqual({ enabled: true });
    expect(q(container, "#mcp-token").textContent).toBe(TOKEN);
  });

  it("Regenerate calls regenerateMcpToken and swaps in the new token everywhere", async () => {
    const NEW = "tok_live_zzz999newnew";
    regenerateMcpToken.mockResolvedValue({ success: true, data: { token: NEW } });
    const { container } = renderSection();
    await waitFor(() => expect(q(container, "#mcp-regenerate-token")).not.toBeNull());
    expect(q(container, "#mcp-token").textContent).toBe(TOKEN);

    fireEvent.click(q(container, "#mcp-regenerate-token"));

    await waitFor(() => expect(q(container, "#mcp-token").textContent).toBe(NEW));
    expect(regenerateMcpToken).toHaveBeenCalledTimes(1);
    // the fresh token flows into the snippets too
    expect(q(container, '[data-mcp-client="claude-code"]').textContent).toContain(`Bearer ${NEW}`);
  });

  it("surfaces a load error through onError", async () => {
    mcpSettings.mockResolvedValue({ success: false, errors: [{ message: "boom" }] });
    const { onError, container } = renderSection();
    await waitFor(() => expect(onError).toHaveBeenCalledWith("boom"));
    expect(container.querySelector("#mcp-enabled-toggle")).toBeNull();
  });
});
