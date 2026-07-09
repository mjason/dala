import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { I18nProvider } from "./i18n";
import Windowed from "./Windowed";

function renderWindow(onClose = vi.fn()) {
  render(
    <I18nProvider>
      <Windowed id="test-window" onClose={onClose} title={<span>title</span>}>
        <div>body content</div>
      </Windowed>
    </I18nProvider>,
  );
  return onClose;
}

beforeEach(() => {
  localStorage.clear();
});

describe("Windowed", () => {
  it("defaults to centered mode", () => {
    renderWindow();
    expect(document.getElementById("test-window")).toHaveAttribute("data-window-mode", "center");
  });

  it("switches modes and persists the choice", () => {
    renderWindow();

    fireEvent.click(document.querySelector('[data-window-mode-button="right"]')!);
    expect(document.getElementById("test-window")).toHaveAttribute("data-window-mode", "right");
    expect(localStorage.getItem("dala:window-mode")).toBe("right");
  });

  it("restores the persisted mode on next open", () => {
    localStorage.setItem("dala:window-mode", "full");
    renderWindow();
    expect(document.getElementById("test-window")).toHaveAttribute("data-window-mode", "full");
  });

  it("closes on backdrop click in centered mode", () => {
    const onClose = renderWindow();
    // the overlay is the window panel's parent
    const overlay = document.getElementById("test-window")!.parentElement!;
    fireEvent.click(overlay);
    expect(onClose).toHaveBeenCalled();
  });

  it("does not close on outside click when docked (terminal stays usable)", () => {
    localStorage.setItem("dala:window-mode", "right");
    const onClose = renderWindow();
    const overlay = document.getElementById("test-window")!.parentElement!;
    fireEvent.click(overlay);
    expect(onClose).not.toHaveBeenCalled();
  });

  it("closes via the close button in any mode", () => {
    localStorage.setItem("dala:window-mode", "left");
    const onClose = renderWindow();
    const header = document.querySelector("#test-window > header")!;
    const buttons = header.querySelectorAll("button");
    fireEvent.click(buttons[buttons.length - 1]);
    expect(onClose).toHaveBeenCalled();
  });
});
