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
    ephemeral: false,
    position: 1,
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
    ephemeral: false,
    position: 2,
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
    onDelete: vi.fn(),
    onReorder: vi.fn(),
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

  it("requests a delete without selecting the row", () => {
    const props = renderSidebar();
    fireEvent.click(document.querySelector('[data-delete-session="s2"]')!);
    expect(props.onDelete).toHaveBeenCalledWith("s2");
    expect(props.onSelect).not.toHaveBeenCalled();
  });

  describe("drag to reorder", () => {
    /** Give each session row a real vertical layout (jsdom rects are 0). */
    function layoutRows() {
      document.querySelectorAll<HTMLElement>("[data-session-row]").forEach((row, i) => {
        row.getBoundingClientRect = () =>
          ({ top: i * 40, height: 40, bottom: i * 40 + 40 }) as DOMRect;
      });
    }

    it("renders a drag handle per session row", () => {
      renderSidebar();
      expect(document.querySelector('[data-drag-session="s1"]')).toBeTruthy();
      expect(document.querySelector('[data-drag-session="s2"]')).toBeTruthy();
    });

    it("commits a reorder on drag past the threshold", () => {
      const props = renderSidebar();
      layoutRows();
      const handle = document.querySelector('[data-drag-session="s2"]')!;
      fireEvent.pointerDown(handle, { pointerId: 1, clientY: 60, button: 0 });
      fireEvent.pointerMove(window, { pointerId: 1, clientY: 10 });
      fireEvent.pointerUp(window, { pointerId: 1, clientY: 10 });
      expect(props.onReorder).toHaveBeenCalledWith("s2", "s1");
      expect(props.onSelect).not.toHaveBeenCalled();
    });

    it("moving below every other row commits with a null beforeId", () => {
      const props = renderSidebar();
      layoutRows();
      const handle = document.querySelector('[data-drag-session="s1"]')!;
      fireEvent.pointerDown(handle, { pointerId: 1, clientY: 20, button: 0 });
      fireEvent.pointerMove(window, { pointerId: 1, clientY: 70 });
      fireEvent.pointerUp(window, { pointerId: 1, clientY: 70 });
      expect(props.onReorder).toHaveBeenCalledWith("s1", null);
    });

    it("does nothing below the movement threshold, and a handle click never selects", () => {
      const props = renderSidebar();
      layoutRows();
      const handle = document.querySelector('[data-drag-session="s2"]')!;
      fireEvent.pointerDown(handle, { pointerId: 1, clientY: 60, button: 0 });
      fireEvent.pointerMove(window, { pointerId: 1, clientY: 62 });
      fireEvent.pointerUp(window, { pointerId: 1, clientY: 62 });
      fireEvent.click(handle);
      expect(props.onReorder).not.toHaveBeenCalled();
      expect(props.onSelect).not.toHaveBeenCalled();
    });

    it("does not commit when the row is dropped where it already was", () => {
      const props = renderSidebar();
      layoutRows();
      const handle = document.querySelector('[data-drag-session="s2"]')!;
      fireEvent.pointerDown(handle, { pointerId: 1, clientY: 60, button: 0 });
      fireEvent.pointerMove(window, { pointerId: 1, clientY: 75 });
      fireEvent.pointerUp(window, { pointerId: 1, clientY: 75 });
      expect(props.onReorder).not.toHaveBeenCalled();
    });

    it("Escape cancels the drag: no commit, indicator gone", () => {
      const props = renderSidebar();
      layoutRows();
      const handle = document.querySelector('[data-drag-session="s2"]')!;
      fireEvent.pointerDown(handle, { pointerId: 1, clientY: 60, button: 0 });
      fireEvent.pointerMove(window, { pointerId: 1, clientY: 10 });
      fireEvent.keyDown(window, { key: "Escape" });
      // The lingering pointerup must not resurrect the drop.
      fireEvent.pointerUp(window, { pointerId: 1, clientY: 10 });
      expect(props.onReorder).not.toHaveBeenCalled();
    });

    it("commits against the list as it is at DROP time, not at pointerdown", () => {
      // The list can change under a live drag (another device reorders, a
      // session is deleted): the drop must resolve its neighbour from the
      // CURRENT rows, not the pointerdown-frozen ones.
      const third: Session = {
        ...sessions[0],
        id: "s3",
        name: "extra",
        position: 3,
        insertedAt: "2026-07-08T02:00:00Z",
      };
      const props = {
        sessions: [...sessions, third],
        activeId: "s1",
        connected: true,
        creating: false,
        onSelect: vi.fn(),
        onCreate: vi.fn(),
        onOpenSettings: vi.fn(),
        onDelete: vi.fn(),
        onReorder: vi.fn(),
      };
      const view = render(
        <I18nProvider>
          <Sidebar {...props} />
        </I18nProvider>,
      );
      layoutRows();

      // Drag s3 (row 3) up to the front slot.
      const handle = document.querySelector('[data-drag-session="s3"]')!;
      fireEvent.pointerDown(handle, { pointerId: 1, clientY: 100, button: 0 });
      fireEvent.pointerMove(window, { pointerId: 1, clientY: 5 });

      // Mid-drag, s1 disappears (deleted elsewhere): the list is now
      // [s2, s3].
      view.rerender(
        <I18nProvider>
          <Sidebar {...props} sessions={[sessions[1], third]} />
        </I18nProvider>,
      );
      layoutRows();

      fireEvent.pointerUp(window, { pointerId: 1, clientY: 5 });
      // Front slot of the CURRENT list = before s2. A stale resolution
      // would have named the vanished s1.
      expect(props.onReorder).toHaveBeenCalledWith("s3", "s2");
    });
  });

  it("switches languages via the footer select", () => {
    renderSidebar();
    const select = document.getElementById("language-select") as HTMLSelectElement;
    fireEvent.change(select, { target: { value: "zh-CN" } });
    expect(screen.getByTitle("新建终端")).toBeInTheDocument();
  });
});
