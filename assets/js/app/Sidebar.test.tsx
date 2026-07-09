import React from "react";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import Sidebar from "./Sidebar";
import type { Session } from "./Sidebar";
import { I18nProvider } from "./i18n";

const sessions: Session[] = [
  {
    id: "s1",
    name: "build",
    shell: "/bin/zsh",
    cwd: "/home/mj/dev",
    status: "running",
    exitCode: null,
    scrollbackLimit: 5_242_880,
    insertedAt: "2026-07-08T00:00:00Z",
  },
  {
    id: "s2",
    name: "logs",
    shell: "/bin/zsh",
    cwd: "/var/log",
    status: "exited",
    exitCode: 0,
    scrollbackLimit: 5_242_880,
    insertedAt: "2026-07-08T01:00:00Z",
  },
];

function renderSidebar(overrides: Partial<React.ComponentProps<typeof Sidebar>> = {}) {
  const props = {
    sessions,
    activeId: "s1",
    connected: true,
    creating: false,
    onSelect: vi.fn(),
    onCreate: vi.fn(),
    onOpenSettings: vi.fn(),
    ...overrides,
  };
  render(
    <I18nProvider>
      <Sidebar {...props} />
    </I18nProvider>,
  );
  return props;
}

describe("Sidebar", () => {
  it("lists sessions with their cwd", () => {
    renderSidebar();
    expect(screen.getByText("build")).toBeInTheDocument();
    expect(screen.getByText("logs")).toBeInTheDocument();
    expect(screen.getByText("/home/mj/dev")).toBeInTheDocument();
  });

  it("selects a session on click", () => {
    const props = renderSidebar();
    fireEvent.click(screen.getByText("logs"));
    expect(props.onSelect).toHaveBeenCalledWith("s2");
  });

  it("creates a terminal from the + button", () => {
    const props = renderSidebar();
    fireEvent.click(document.getElementById("new-session-button")!);
    expect(props.onCreate).toHaveBeenCalled();
  });

  it("shows an empty state that can create a terminal", () => {
    const props = renderSidebar({ sessions: [], activeId: null });
    fireEvent.click(screen.getByText(/new terminal/i));
    expect(props.onCreate).toHaveBeenCalled();
  });

  it("switches languages via the footer select", () => {
    renderSidebar();
    const select = document.getElementById("language-select") as HTMLSelectElement;
    fireEvent.change(select, { target: { value: "zh-CN" } });
    expect(screen.getByTitle("新建终端")).toBeInTheDocument();
  });
});
