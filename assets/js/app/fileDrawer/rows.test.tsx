import React from "react";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { compactPath, placeTooltip, Row } from "./rows";

afterEach(() => {
  vi.useRealTimers();
});

describe("compactPath", () => {
  it("keeps short paths unchanged", () => {
    expect(compactPath("/home/mj/dala/lib/app.ex")).toBe("/home/mj/dala/lib/app.ex");
  });

  it("shortens directory segments but always keeps the complete file name", () => {
    const name = "terminal-session-output-with-a-complete-name.component.tsx";
    const path =
      `/home/michael/development/projects/dala/assets/javascript/application/components/fileDrawer/${name}`;
    const compact = compactPath(path);

    expect(compact).toBe(`/home/.../fileDrawer/${name}`);
    expect(compact.endsWith(name)).toBe(true);
  });
});

describe("placeTooltip", () => {
  const tooltip = { width: 240, height: 72 };
  const viewport = { width: 1_000, height: 700 };

  it("opens to the left of a row near the right viewport edge", () => {
    expect(
      placeTooltip({ left: 720, right: 980, top: 80, bottom: 108 }, tooltip, viewport),
    ).toEqual({ left: 472, top: 80, placement: "left" });
  });

  it("stays inside a narrow viewport when neither side has room", () => {
    const position = placeTooltip(
      { left: 20, right: 370, top: 100, bottom: 128 },
      { width: 350, height: 72 },
      { width: 390, height: 700 },
    );

    expect(position).toEqual({ left: 20, top: 136, placement: "below" });
  });
});

describe("Row path tooltip", () => {
  function renderRow() {
    const name = "a-file-name-that-must-never-be-truncated.tsx";
    const path = `/home/michael/development/projects/dala/components/fileDrawer/${name}`;
    render(
      <Row
        path={path}
        depth={0}
        icon={null}
        extraIcon={null}
        name={name}
        decoration={{ label: "M", title: "Modified", tone: "modified" }}
        onClick={() => {}}
      />,
    );
    return { name, path, row: screen.getByRole("treeitem") };
  }

  it("shows the full name and compact path after a short delay", () => {
    vi.useFakeTimers();
    const { name, path, row } = renderRow();

    expect(row).not.toHaveAttribute("title");
    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(349));
    expect(screen.queryByRole("tooltip")).toBeNull();

    act(() => vi.advanceTimersByTime(1));
    const tooltip = screen.getByRole("tooltip");
    expect(tooltip.querySelector("[data-tooltip-name]")).toHaveTextContent(name);
    expect(tooltip.querySelector("[data-tooltip-path]")).toHaveAttribute("aria-label", path);
    expect(tooltip.querySelector("[data-tooltip-path]")?.textContent?.endsWith(name)).toBe(true);
    expect(row).toHaveAttribute("aria-describedby", tooltip.id);
  });

  it("dismisses on drawer scroll and Escape", () => {
    vi.useFakeTimers();
    const { row } = renderRow();

    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(350));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.scroll(window);
    expect(screen.queryByRole("tooltip")).toBeNull();

    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(350));
    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("supports keyboard focus and cancels pending hover on leave", () => {
    vi.useFakeTimers();
    const { row } = renderRow();

    fireEvent.mouseEnter(row);
    fireEvent.mouseLeave(row);
    act(() => vi.advanceTimersByTime(350));
    expect(screen.queryByRole("tooltip")).toBeNull();

    fireEvent.focus(row);
    act(() => vi.advanceTimersByTime(350));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.blur(row);
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("a press ANYWHERE cancels a pending tip — the stuck-over-preview regression", () => {
    vi.useFakeTimers();
    const { row } = renderRow();

    // Hover arms the 350ms timer; clicking the row opens a full-screen
    // preview over a stationary pointer (no mouseleave ever follows). The
    // press must cancel the timer or the tip pops on top of the preview.
    fireEvent.mouseEnter(row);
    fireEvent.pointerDown(row);
    act(() => vi.advanceTimersByTime(350));
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("a press anywhere also closes an already-open tip", () => {
    vi.useFakeTimers();
    const { row } = renderRow();

    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(350));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.pointerDown(document.body);
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("pointer hovering anything OUTSIDE the row closes the tip; inside keeps it", () => {
    vi.useFakeTimers();
    const { row } = renderRow();

    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(350));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();

    // Moving across the row's own children keeps the tip up.
    fireEvent.pointerOver(row.querySelector("span")!);
    expect(screen.getByRole("tooltip")).toBeInTheDocument();

    // First pointer contact with anything else (an overlay that swallowed
    // the mouseleave, the table under it, …) dismisses immediately.
    fireEvent.pointerOver(document.body);
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("re-hovering after a press-cancel arms the tip again", () => {
    vi.useFakeTimers();
    const { row } = renderRow();

    fireEvent.mouseEnter(row);
    fireEvent.pointerDown(row);
    fireEvent.mouseLeave(row);

    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(350));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
  });
});
