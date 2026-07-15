import React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render } from "@testing-library/react";
import { I18nProvider } from "./i18n";

// jsdom ships no scroll engine; the modal resets its body scroll on tab change.
if (typeof Element.prototype.scrollTo !== "function") {
  Element.prototype.scrollTo = () => {};
}

// mcpEnabled comes from the server-rendered <meta name="mcp-enabled">. A getter
// lets each test flip the value that the live import binding reads at render.
let mcpEnabledValue = false;
vi.mock("./meta", () => ({
  get mcpEnabled() {
    return mcpEnabledValue;
  },
  authEnabled: false,
  userEmail: null,
  socketToken: null,
  serverVersion: null,
}));

// Keep the heavy setting panels out of this unit — only the tab strip matters.
vi.mock("./settings/AppearanceSection", () => ({ default: () => null }));
vi.mock("./settings/NotificationsSection", () => ({ default: () => null }));
vi.mock("./settings/ShortcutsSection", () => ({ default: () => null }));
vi.mock("./settings/SpeechSection", () => ({ default: () => null }));
vi.mock("./settings/McpSection", () => ({ default: () => <div id="mcp-section" /> }));

vi.mock("../ash_rpc", () => ({
  closeSession: vi.fn(),
  deleteSession: vi.fn(),
  kickViewers: vi.fn(),
  renameSession: vi.fn(),
  restartSession: vi.fn(),
  setScrollbackLimit: vi.fn(),
}));

import SettingsModal from "./SettingsModal";

const session = {
  id: "11111111-1111-1111-1111-111111111111",
  name: "test",
  shell: "zsh",
  cwd: "/home/mj",
  status: "running" as const,
  exitCode: null,
  scrollbackLimit: 10_000,
  ephemeral: false,
  position: 0,
  insertedAt: "2026-01-01T00:00:00Z",
};

function renderModal() {
  return render(
    <I18nProvider>
      <SettingsModal
        session={session}
        onClose={() => {}}
        onDeleted={() => {}}
        onError={() => {}}
      />
    </I18nProvider>,
  );
}

afterEach(cleanup);

describe("SettingsModal MCP tab gating", () => {
  it("shows the MCP tab when the server has MCP enabled", () => {
    mcpEnabledValue = true;
    const { container } = renderModal();
    expect(container.querySelector('[data-settings-tab="mcp"]')).not.toBeNull();
  });

  it("hides the MCP tab when the server has MCP disabled", () => {
    mcpEnabledValue = false;
    const { container } = renderModal();
    expect(container.querySelector('[data-settings-tab="mcp"]')).toBeNull();
    // the always-present tabs still render
    expect(container.querySelector('[data-settings-tab="session"]')).not.toBeNull();
    expect(container.querySelector('[data-settings-tab="appearance"]')).not.toBeNull();
  });
});
