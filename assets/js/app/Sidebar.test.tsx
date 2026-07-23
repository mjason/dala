import React from "react";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import Sidebar from "./Sidebar";
import type { Session } from "./Sidebar";
import { I18nProvider } from "./i18n";

// Sidebar tests cover list interactions; the footer's network-backed update
// checker has its own suite and must not leave a Phoenix reconnect timer
// running after jsdom tears down this test's window.
vi.mock("./UpdateCheck", () => ({ default: () => null }));

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
    group: null,
    position: 1,
    insertedAt: "2026-07-08T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00.000000Z",
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
    group: null,
    position: 2,
    insertedAt: "2026-07-08T01:00:00Z",
    updatedAt: "2026-01-01T00:00:00.000000Z",
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
    onDeleteMany: vi.fn(),
    onSetGroup: vi.fn(),
    onReorder: vi.fn(),
    onReorderMany: vi.fn(),
    renamingId: null as string | null,
    onRenameStart: vi.fn(),
    onRename: vi.fn(),
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

  describe("inline rename", () => {
    const input = () =>
      document.querySelector<HTMLInputElement>('[data-rename-session="s1"]');

    it("shows no input until a rename starts", () => {
      renderSidebar();
      expect(input()).toBeNull();
      expect(screen.getByText("build")).toBeInTheDocument();
    });

    it("starts a rename on a double click of the name", () => {
      const props = renderSidebar();
      fireEvent.doubleClick(screen.getByText("logs"));
      expect(props.onRenameStart).toHaveBeenCalledWith("s2");
    });

    it("edits the active row in place, seeded with the current name", () => {
      renderSidebar({ renamingId: "s1" });
      expect(input()).not.toBeNull();
      expect(input()!.value).toBe("build");
      // The static name is replaced by the input, not shown alongside it.
      expect(screen.queryByText("build")).toBeNull();
    });

    it("commits on Enter", () => {
      const props = renderSidebar({ renamingId: "s1" });
      fireEvent.change(input()!, { target: { value: "  deploy  " } });
      fireEvent.keyDown(input()!, { key: "Enter" });
      expect(props.onRename).toHaveBeenCalledWith("s1", "deploy");
      expect(props.onRenameStart).toHaveBeenCalledWith(null);
    });

    it("commits on blur", () => {
      const props = renderSidebar({ renamingId: "s1" });
      fireEvent.change(input()!, { target: { value: "deploy" } });
      fireEvent.blur(input()!);
      expect(props.onRename).toHaveBeenCalledWith("s1", "deploy");
      expect(props.onRenameStart).toHaveBeenCalledWith(null);
    });

    it("cancels on Escape, and a later blur commits nothing", () => {
      const props = renderSidebar({ renamingId: "s1" });
      fireEvent.change(input()!, { target: { value: "deploy" } });
      fireEvent.keyDown(input()!, { key: "Escape" });
      fireEvent.blur(input()!);
      expect(props.onRename).not.toHaveBeenCalled();
      expect(props.onRenameStart).toHaveBeenCalledWith(null);
    });

    it("keeps Escape away from the window-level handlers", () => {
      const onWindowEscape = vi.fn();
      window.addEventListener("keydown", onWindowEscape);
      renderSidebar({ renamingId: "s1" });
      const event = new KeyboardEvent("keydown", {
        key: "Escape",
        bubbles: true,
        cancelable: true,
      });
      input()!.dispatchEvent(event);
      window.removeEventListener("keydown", onWindowEscape);
      expect(onWindowEscape).not.toHaveBeenCalled();
      expect(event.defaultPrevented).toBe(true);
    });

    it("commits nothing when the name is unchanged or blank", () => {
      const props = renderSidebar({ renamingId: "s1" });
      fireEvent.keyDown(input()!, { key: "Enter" });
      expect(props.onRename).not.toHaveBeenCalled();
      expect(props.onRenameStart).toHaveBeenCalledWith(null);

      const blank = renderSidebar({ renamingId: "s1" });
      const inputs = document.querySelectorAll<HTMLInputElement>('[data-rename-session="s1"]');
      const second = inputs[inputs.length - 1];
      fireEvent.change(second, { target: { value: "   " } });
      fireEvent.keyDown(second, { key: "Enter" });
      expect(blank.onRename).not.toHaveBeenCalled();
    });

    it("does not select the row while editing", () => {
      const props = renderSidebar({ renamingId: "s1" });
      fireEvent.click(input()!);
      expect(props.onSelect).not.toHaveBeenCalled();
    });
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
        updatedAt: "2026-01-01T00:00:00.000000Z",
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
        renamingId: null,
        onRenameStart: vi.fn(),
        onRename: vi.fn(),
        onDeleteMany: vi.fn(),
        onSetGroup: vi.fn(),
        onReorderMany: vi.fn(),
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

  it("shows an interaction hints bar under the list", () => {
    renderSidebar();
    const hints = document.querySelector("#session-hints");
    expect(hints).not.toBeNull();
    expect(hints!.textContent).toContain("Shift");
  });

describe("Sidebar context menu", () => {
  const menu = () => document.querySelector("#session-context-menu");
  const pick = (key: string) =>
    fireEvent.click(document.querySelector(`[data-ctx-item="${key}"]`)!);
  const rightClickRow = (id: string) =>
    fireEvent.contextMenu(document.querySelector(`[data-session-row="${id}"]`)!);

  it("opens on right click and toggles the row into the selection", () => {
    renderSidebar();
    expect(menu()).toBeNull();
    rightClickRow("s2");
    expect(menu()).not.toBeNull();
    pick("toggle-select");
    expect(menu()).toBeNull();
    expect(document.querySelector('[data-session-row="s2"][data-selected]')).not.toBeNull();
    // The multibar surfaces at the bottom with the batch-delete action.
    expect(document.querySelector("#session-multibar")).not.toBeNull();
    expect(document.querySelector("#delete-selected-button")).not.toBeNull();
  });

  it("offers batch delete when the row is part of a multi-selection", () => {
    const props = renderSidebar();
    fireEvent.click(document.querySelector('[data-session-row="s1"]')!, { ctrlKey: true });
    fireEvent.click(document.querySelector('[data-session-row="s2"]')!, { ctrlKey: true });
    rightClickRow("s2");
    pick("delete-selected");
    expect(props.onDeleteMany).toHaveBeenCalledWith(expect.arrayContaining(["s1", "s2"]));
  });

  it("routes rename, settings and delete to the row's session", () => {
    const props = renderSidebar();
    rightClickRow("s2");
    pick("rename");
    expect(props.onRenameStart).toHaveBeenCalledWith("s2");
    rightClickRow("s2");
    pick("settings");
    expect(props.onOpenSettings).toHaveBeenCalledWith("s2");
    rightClickRow("s2");
    pick("delete");
    expect(props.onDelete).toHaveBeenCalledWith("s2");
  });

  it("hovering move-to-group opens the flyout submenu", () => {
    renderSidebar();
    rightClickRow("s1");
    const wrapper = document.querySelector('[data-ctx-item="move"]')!.parentElement!;
    fireEvent.mouseEnter(wrapper);
    expect(document.querySelector("#session-group-flyout")).not.toBeNull();
    expect(document.querySelector('[data-ctx-item="new-group"]')).not.toBeNull();
    fireEvent.mouseLeave(wrapper);
    expect(document.querySelector("#session-group-flyout")).toBeNull();
  });

  it("moves a session into a new group via the naming dialog", () => {
    const props = renderSidebar();
    rightClickRow("s1");
    pick("move");
    // Second level: no groups exist yet, only "new group…".
    pick("new-group");
    const input = document.querySelector<HTMLInputElement>("#group-name-input")!;
    fireEvent.change(input, { target: { value: "  work  " } });
    fireEvent.submit(document.querySelector("#group-name-modal")!);
    expect(props.onSetGroup).toHaveBeenCalledWith(["s1"], "work");
    expect(document.querySelector("#group-name-modal")).toBeNull();
  });

  it("lists existing groups as move targets and offers remove-from-group", () => {
    const grouped = [{ ...sessions[0], group: "work" }, sessions[1]];
    const props = renderSidebar({ sessions: grouped });
    rightClickRow("s2");
    pick("move");
    pick("move-to:work");
    expect(props.onSetGroup).toHaveBeenCalledWith(["s2"], "work");
    // A grouped row offers the way back out.
    rightClickRow("s1");
    pick("move");
    pick("remove-from-group");
    expect(props.onSetGroup).toHaveBeenCalledWith(["s1"], null);
  });

  it("group header menu selects, renames, ungroups and deletes the whole group", () => {
    const grouped = sessions.map((s) => ({ ...s, group: "work" }));
    const props = renderSidebar({ sessions: grouped });
    const header = document.querySelector('[data-session-group="work"]')!;
    fireEvent.contextMenu(header);
    pick("select-group");
    expect(document.querySelectorAll("[data-session-row][data-selected]").length).toBe(2);
    fireEvent.contextMenu(header);
    pick("rename-group");
    const input = document.querySelector<HTMLInputElement>("#group-name-input")!;
    expect(input.value).toBe("work");
    fireEvent.change(input, { target: { value: "play" } });
    fireEvent.submit(document.querySelector("#group-name-modal")!);
    expect(props.onSetGroup).toHaveBeenCalledWith(["s1", "s2"], "play");
    fireEvent.contextMenu(header);
    pick("ungroup");
    expect(props.onSetGroup).toHaveBeenCalledWith(["s1", "s2"], null);
    fireEvent.contextMenu(header);
    pick("delete-group");
    expect(props.onDeleteMany).toHaveBeenCalledWith(["s1", "s2"]);
  });

  it("Escape closes the menu without clearing the selection", () => {
    renderSidebar();
    fireEvent.click(document.querySelector('[data-session-row="s1"]')!, { ctrlKey: true });
    rightClickRow("s1");
    expect(menu()).not.toBeNull();
    fireEvent.keyDown(window, { key: "Escape" });
    expect(menu()).toBeNull();
    expect(document.querySelector('[data-session-row="s1"][data-selected]')).not.toBeNull();
  });
});

describe("Sidebar group actions", () => {
  it("multibar offers move-to-group for the whole selection and clears it after", () => {
    const props = renderSidebar();
    fireEvent.click(document.querySelector('[data-session-row="s1"]')!, { ctrlKey: true });
    fireEvent.click(document.querySelector('[data-session-row="s2"]')!, { ctrlKey: true });
    fireEvent.click(document.querySelector("#group-selected-button")!);
    const input = document.querySelector<HTMLInputElement>("#group-name-input")!;
    fireEvent.change(input, { target: { value: "work" } });
    fireEvent.submit(document.querySelector("#group-name-modal")!);
    expect(props.onSetGroup).toHaveBeenCalledWith(
      expect.arrayContaining(["s1", "s2"]),
      "work",
    );
    // Action done — the selection (and multibar) goes away.
    expect(document.querySelector("#session-multibar")).toBeNull();
  });

  it("the naming dialog suggests existing group names", () => {
    const grouped = [{ ...sessions[0], group: "work" }, sessions[1]];
    renderSidebar({ sessions: grouped });
    fireEvent.contextMenu(document.querySelector('[data-session-row="s2"]')!);
    fireEvent.click(document.querySelector('[data-ctx-item="move"]')!);
    fireEvent.click(document.querySelector('[data-ctx-item="new-group"]')!);
    const options = Array.from(
      document.querySelectorAll("#session-group-names option"),
    ).map((o) => (o as HTMLOptionElement).value);
    expect(options).toEqual(["work"]);
  });

  it("dragging a group header moves the whole group to the drop position", () => {
    const three = [
      { ...sessions[0], group: "work" },
      { ...sessions[1], id: "s2", group: "work" },
      { ...sessions[1], id: "s3", group: null },
    ];
    const props = renderSidebar({ sessions: three });
    document.querySelectorAll<HTMLElement>("[data-session-row]").forEach((row, i) => {
      row.getBoundingClientRect = () =>
        ({ top: i * 40, height: 40, bottom: i * 40 + 40 }) as DOMRect;
    });

    const handle = document.querySelector('[data-drag-group="work"]')!;
    fireEvent.pointerDown(handle, { pointerId: 1, clientY: 0, button: 0 });
    // Below every row → drop at the end.
    fireEvent.pointerMove(window, { pointerId: 1, clientY: 500 });
    fireEvent.pointerUp(window, { pointerId: 1, clientY: 500 });
    expect(props.onReorderMany).toHaveBeenCalledWith(["s1", "s2"], null);
  });

  it("a drop inside another group snaps to that group's start (never splits it)", () => {
    const four = [
      { ...sessions[0], group: "a" },
      { ...sessions[1], id: "s2", group: "b" },
      { ...sessions[1], id: "s3", group: "b" },
    ];
    const props = renderSidebar({ sessions: four });
    document.querySelectorAll<HTMLElement>("[data-session-row]").forEach((row, i) => {
      row.getBoundingClientRect = () =>
        ({ top: i * 40, height: 40, bottom: i * 40 + 40 }) as DOMRect;
    });

    const handle = document.querySelector('[data-drag-group="a"]')!;
    fireEvent.pointerDown(handle, { pointerId: 1, clientY: 0, button: 0 });
    // Between s2 and s3 (inside group b) → snaps to s2, group b's start.
    fireEvent.pointerMove(window, { pointerId: 1, clientY: 95 });
    fireEvent.pointerUp(window, { pointerId: 1, clientY: 95 });
    expect(props.onReorderMany).toHaveBeenCalledWith(["s1"], "s2");
  });

  it("a click on the header without crossing the threshold still just toggles collapse", () => {
    const grouped = sessions.map((s) => ({ ...s, group: "work" }));
    const props = renderSidebar({ sessions: grouped });
    const handle = document.querySelector('[data-drag-group="work"]')!;
    fireEvent.pointerDown(handle, { pointerId: 1, clientY: 10, button: 0 });
    fireEvent.pointerUp(window, { pointerId: 1, clientY: 12 });
    expect(props.onReorderMany).not.toHaveBeenCalled();
  });
});
