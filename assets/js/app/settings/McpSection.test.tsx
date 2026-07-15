import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { I18nProvider } from "../i18n";

// The clipboard helper degrades gracefully in prod; here we just watch it.
const writeClipboard = vi.fn().mockResolvedValue(true);
vi.mock("../util", () => ({
  writeClipboard: (...a: unknown[]) => writeClipboard(...a),
}));

import McpSection from "./McpSection";

function renderSection() {
  return render(
    <I18nProvider>
      <McpSection />
    </I18nProvider>,
  );
}

const q = (c: HTMLElement, sel: string) => c.querySelector(sel) as HTMLElement;

const ORIGIN = window.location.origin;
const ENDPOINT = `${ORIGIN}/mcp`;

beforeEach(() => {
  writeClipboard.mockClear();
});
afterEach(cleanup);

describe("McpSection", () => {
  it("shows the LIVE MCP endpoint URL (origin + /mcp)", () => {
    const { container } = renderSection();
    const url = q(container, "#mcp-endpoint-url");
    expect(url).not.toBeNull();
    expect(url.textContent).toBe(ENDPOINT);
    expect(url.textContent).toContain("/mcp");
  });

  it("renders connect blocks for all three clients", () => {
    const { container } = renderSection();
    for (const client of ["claude-code", "codex", "opencode"]) {
      expect(q(container, `[data-mcp-client="${client}"]`)).not.toBeNull();
    }
  });

  it("each client snippet carries the live origin and only the token PLACEHOLDER", () => {
    const { container } = renderSection();
    for (const client of ["claude-code", "codex", "opencode"]) {
      const block = q(container, `[data-mcp-client="${client}"]`);
      const text = block.textContent ?? "";
      // live endpoint, verbatim
      expect(text).toContain(ENDPOINT);
      // the placeholder, never a real secret — always angle-bracketed
      expect(text).toContain("DALA_MCP_TOKEN");
      expect(text).toMatch(/Bearer <[^>]*DALA_MCP_TOKEN>/);
    }
  });

  it("uses the source-verified flags per client", () => {
    const { container } = renderSection();
    const claude = q(container, `[data-mcp-client="claude-code"]`).textContent ?? "";
    expect(claude).toContain("claude mcp add --transport http dala");
    const codex = q(container, `[data-mcp-client="codex"]`).textContent ?? "";
    expect(codex).toContain("[mcp_servers.dala]");
    expect(codex).toContain("http_headers");
    const opencode = q(container, `[data-mcp-client="opencode"]`).textContent ?? "";
    expect(opencode).toContain('"type": "remote"');
  });

  it("copy button writes the snippet to the clipboard", async () => {
    const { container } = renderSection();
    const block = q(container, `[data-mcp-client="claude-code"]`);
    const copyBtn = block.querySelector("[data-mcp-copy]") as HTMLElement;
    expect(copyBtn).not.toBeNull();
    fireEvent.click(copyBtn);
    expect(writeClipboard).toHaveBeenCalledTimes(1);
    const arg = writeClipboard.mock.calls[0][0] as string;
    expect(arg).toContain(ENDPOINT);
    expect(arg).toContain("claude mcp add");
  });

  it("lists example prompts that each invoke the dala MCP", () => {
    const { container } = renderSection();
    const items = Array.from(container.querySelectorAll("li"));
    expect(items.length).toBeGreaterThanOrEqual(3);
    for (const li of items) {
      expect(li.textContent ?? "").toContain("dala MCP");
    }
  });
});
