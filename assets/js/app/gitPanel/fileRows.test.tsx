import React from "react";
import { act, fireEvent, render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { FileRow } from "./fileRows";

describe("GitPanel status theme tokens", () => {
  it("keeps textual state labels and maps every state to its semantic theme colour", () => {
    const states = [
      ["A ", "A", "text-git-added"],
      [" M", "M", "text-git-modified"],
      [" D", "D", "text-git-deleted"],
      ["R ", "R", "text-git-renamed"],
      ["??", "U", "text-git-untracked"],
      ["UU", "!", "text-git-conflict"],
    ] as const;

    const { container } = render(
      <>
        {states.map(([status], index) => (
          <FileRow
            key={status}
            file={{ path: `file-${index}.txt`, status, staged: false, unstaged: true }}
            busy={null}
            onOpen={vi.fn()}
            actions={[]}
          />
        ))}
      </>,
    );

    const badges = container.querySelectorAll(".font-semibold");
    expect(badges).toHaveLength(states.length);
    states.forEach(([_status, label, className], index) => {
      expect(badges[index]).toHaveTextContent(label);
      expect(badges[index]).toHaveClass(className);
    });
  });

  it("shows the full file name and absolute path on hover", () => {
    vi.useFakeTimers();
    const file = {
      path: "lib/dala_web/components/very_long_terminal_component.ex",
      status: " M",
      staged: false,
      unstaged: true,
    };
    const { container } = render(
      <FileRow
        file={file}
        root="/home/mj/dev/elixir/dala"
        busy={null}
        onOpen={vi.fn()}
        actions={[]}
      />,
    );

    fireEvent.mouseEnter(container.firstElementChild!);
    act(() => vi.advanceTimersByTime(350));

    const tooltip = document.querySelector("[data-file-path-tooltip]")!;
    expect(tooltip.querySelector("[data-tooltip-name]")).toHaveTextContent(
      "very_long_terminal_component.ex",
    );
    expect(tooltip.querySelector("[data-tooltip-path]")).toHaveAttribute(
      "aria-label",
      "/home/mj/dev/elixir/dala/lib/dala_web/components/very_long_terminal_component.ex",
    );
    vi.useRealTimers();
  });

  it("the git row shares the drawer's dismissal guards: a press or off-row hover closes the tip", () => {
    vi.useFakeTimers();
    const file = { path: "lib/guarded.ex", status: " M", staged: false, unstaged: true };
    const { container } = render(
      <FileRow file={file} root="/repo" busy={null} onOpen={vi.fn()} actions={[]} />,
    );
    const row = container.firstElementChild!;

    // A press anywhere closes an open tip (opening a diff covers the row).
    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(350));
    expect(document.querySelector("[data-file-path-tooltip]")).not.toBeNull();
    fireEvent.pointerDown(row);
    expect(document.querySelector("[data-file-path-tooltip]")).toBeNull();

    // Hovering anything outside the row closes it too.
    fireEvent.mouseLeave(row);
    fireEvent.mouseEnter(row);
    act(() => vi.advanceTimersByTime(350));
    expect(document.querySelector("[data-file-path-tooltip]")).not.toBeNull();
    fireEvent.pointerOver(document.body);
    expect(document.querySelector("[data-file-path-tooltip]")).toBeNull();
    vi.useRealTimers();
  });
});
