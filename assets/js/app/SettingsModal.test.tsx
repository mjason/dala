import React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { I18nProvider } from "./i18n";

// jsdom ships no scroll engine; the modal resets its body scroll on tab change.
if (typeof Element.prototype.scrollTo !== "function") {
  Element.prototype.scrollTo = () => {};
}

// meta is server-rendered; the modal only needs these to exist.
vi.mock("./meta", () => ({
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

describe("SettingsModal tabs", () => {
  it("always shows the MCP tab (enablement is a runtime toggle inside it)", () => {
    const { container } = renderModal();
    expect(container.querySelector('[data-settings-tab="mcp"]')).not.toBeNull();
  });

  it("renders the full always-present tab strip", () => {
    const { container } = renderModal();
    for (const key of ["session", "appearance", "shortcuts", "voice", "mcp"]) {
      expect(container.querySelector(`[data-settings-tab="${key}"]`)).not.toBeNull();
    }
  });

  it("selecting the MCP tab shows the MCP section", () => {
    const { container } = renderModal();
    fireEvent.click(container.querySelector('[data-settings-tab="mcp"]') as HTMLElement);
    expect(container.querySelector("#mcp-section")).not.toBeNull();
  });
});
