import React from "react";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render } from "@testing-library/react";
import LeaderMenu, { LEADER_TREE } from "./LeaderMenu";
import { I18nProvider } from "./i18n";

function renderMenu(open = true) {
  const props = { open, onClose: vi.fn(), onAction: vi.fn() };
  render(
    <I18nProvider>
      <LeaderMenu {...props} />
    </I18nProvider>,
  );
  return props;
}

describe("LeaderMenu", () => {
  it("renders nothing while closed", () => {
    renderMenu(false);
    expect(document.querySelector("#leader-menu")).toBeNull();
  });

  it("shows the root level with every group and leaf", () => {
    renderMenu();
    for (const node of LEADER_TREE) {
      expect(document.querySelector(`[data-leader-key="${node.key}"]`)).not.toBeNull();
    }
  });

  it("a group key descends; a leaf key runs the action and closes", () => {
    const props = renderMenu();
    fireEvent.keyDown(window, { key: "r" });
    // Now at the rendering level: refit lives on "f".
    expect(document.querySelector('[data-leader-key="f"]')).not.toBeNull();
    fireEvent.keyDown(window, { key: "f" });
    expect(props.onAction).toHaveBeenCalledWith("refit");
    expect(props.onClose).toHaveBeenCalled();
  });

  it("Backspace returns to the root; Escape closes", () => {
    const props = renderMenu();
    fireEvent.keyDown(window, { key: "s" });
    expect(document.querySelector('[data-leader-key="n"]')).not.toBeNull();
    fireEvent.keyDown(window, { key: "Backspace" });
    expect(document.querySelector('[data-leader-key="s"]')).not.toBeNull();
    fireEvent.keyDown(window, { key: "Escape" });
    expect(props.onClose).toHaveBeenCalled();
  });

  it("unknown keys are swallowed, not leaked", () => {
    const props = renderMenu();
    fireEvent.keyDown(window, { key: "z" });
    expect(props.onAction).not.toHaveBeenCalled();
    expect(props.onClose).not.toHaveBeenCalled();
  });

  it("clicking an entry works like its key", () => {
    const props = renderMenu();
    fireEvent.click(document.querySelector('[data-leader-key="f"]')!);
    expect(props.onAction).toHaveBeenCalledWith("quickOpen");
  });

  it("focus returns to the previous element only when NO action ran", () => {
    const input = document.createElement("input");
    document.body.appendChild(input);
    input.focus();

    const props = renderMenu();
    fireEvent.keyDown(window, { key: "f" });
    expect(props.onAction).toHaveBeenCalledWith("quickOpen");
    input.remove();
  });

  it("every leaf key is unique within its level", () => {
    const check = (nodes: typeof LEADER_TREE) => {
      const keys = nodes.map((n) => n.key);
      expect(new Set(keys).size).toBe(keys.length);
      for (const node of nodes) if ("children" in node) check(node.children);
    };
    check(LEADER_TREE);
  });
});
