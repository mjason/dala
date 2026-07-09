import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { I18nProvider } from "./i18n";

const listAgentSessions = vi.fn();
const createAgentSession = vi.fn();
const deleteAgentSession = vi.fn();

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  listAgentSessions: (...a: unknown[]) => listAgentSessions(...a),
  createAgentSession: (...a: unknown[]) => createAgentSession(...a),
  deleteAgentSession: (...a: unknown[]) => deleteAgentSession(...a),
}));

vi.mock("./meta", () => ({
  acpAgents: [
    { id: "opencode", name: "opencode" },
    { id: "claude-code", name: "Claude Code" },
  ],
}));

vi.mock("./AgentView", () => ({
  default: ({ sessionId }: { sessionId: string }) => <div data-agent-view={sessionId} />,
}));

import AgentPanel from "./AgentPanel";

const ok = (data: unknown) => ({ success: true, data });
const session = (id: string, name = "agent") => ({
  id,
  name,
  cwd: "/x",
  status: "ready",
  insertedAt: "2026-07-09T00:00:00Z",
});

function renderPanel(onError = vi.fn()) {
  render(
    <I18nProvider>
      <AgentPanel cwd="/x" onError={onError} />
    </I18nProvider>,
  );
  return onError;
}

beforeEach(() => {
  listAgentSessions.mockReset();
  createAgentSession.mockReset();
  deleteAgentSession.mockReset();
  listAgentSessions.mockResolvedValue(ok([]));
});

describe("AgentPanel", () => {
  it("lists existing agent sessions as tabs", async () => {
    listAgentSessions.mockResolvedValue(ok([session("s1", "one"), session("s2", "two")]));
    renderPanel();
    expect(await screen.findByText("one")).toBeInTheDocument();
    expect(screen.getByText("two")).toBeInTheDocument();
    // the last one is active by default
    await waitFor(() =>
      expect(document.querySelector('[data-agent-view="s2"]')).not.toBeNull(),
    );
  });

  it("offers an agent-kind menu and creates with the chosen kind", async () => {
    listAgentSessions.mockResolvedValue(ok([]));
    createAgentSession.mockResolvedValue(ok(session("new1")));
    renderPanel();

    await waitFor(() => expect(document.getElementById("new-agent-button")).not.toBeNull());
    fireEvent.click(document.getElementById("new-agent-button")!);

    // both installed agents appear in the menu
    expect(await screen.findByText("Claude Code")).toBeInTheDocument();
    fireEvent.click(document.querySelector('[data-agent-kind="claude-code"]')!);

    await waitFor(() =>
      expect(createAgentSession).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({ cwd: "/x", agentKind: "claude-code" }),
        }),
      ),
    );
  });

  it("switches the active session on tab click", async () => {
    listAgentSessions.mockResolvedValue(ok([session("s1", "one"), session("s2", "two")]));
    renderPanel();
    await screen.findByText("one");

    fireEvent.click(document.querySelector('[data-agent-tab="s1"]')!);
    await waitFor(() =>
      expect(document.querySelector('[data-agent-view="s1"]')).not.toBeNull(),
    );
  });

  it("deletes a session", async () => {
    listAgentSessions.mockResolvedValue(ok([session("s1", "one")]));
    deleteAgentSession.mockResolvedValue(ok({}));
    renderPanel();
    await screen.findByText("one");

    fireEvent.click(screen.getByText("✕"));
    await waitFor(() =>
      expect(deleteAgentSession).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "s1" }),
      ),
    );
  });
});
