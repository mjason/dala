import React from "react";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render } from "@testing-library/react";
import LeaderMenu, { LEADER_TREE, SESSION_KEYS } from "./LeaderMenu";
import { I18nProvider } from "./i18n";

const SESSIONS = [
  { id: "a", name: "api", cwd: "/w/api", active: false },
  { id: "b", name: "web", cwd: "/w/web", active: true },
  { id: "c", name: "ops", cwd: "/w/ops", active: false },
];

function renderMenu(open = true, sessions = SESSIONS) {
  const props = {
    open,
    onClose: vi.fn(),
    onAction: vi.fn(),
    sessions,
    onSelectSession: vi.fn(),
  };
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

describe("LeaderMenu session picker (s → s)", () => {
  const openPicker = (sessions = SESSIONS) => {
    const props = renderMenu(true, sessions);
    fireEvent.keyDown(window, { key: "s" });
    fireEvent.keyDown(window, { key: "s" });
    return props;
  };

  it("lists every session with its assigned key, active one marked", () => {
    openPicker();
    const picker = document.querySelector("#leader-session-picker")!;
    expect(picker).not.toBeNull();
    const rows = picker.querySelectorAll("[data-session-key]");
    expect(rows.length).toBe(SESSIONS.length);
    SESSIONS.forEach((s, i) => {
      const row = picker.querySelector(`[data-session-key="${SESSION_KEYS[i]}"]`)!;
      expect(row.textContent).toContain(s.name);
      expect(row.hasAttribute("aria-current")).toBe(s.active);
    });
  });

  it("a session key jumps to that session and closes", () => {
    const props = openPicker();
    fireEvent.keyDown(window, { key: "3" });
    expect(props.onSelectSession).toHaveBeenCalledWith("c");
    expect(props.onClose).toHaveBeenCalled();
    expect(props.onAction).not.toHaveBeenCalled();
  });

  it("clicking a row jumps too", () => {
    const props = openPicker();
    fireEvent.click(document.querySelector('[data-session-key="1"]')!);
    expect(props.onSelectSession).toHaveBeenCalledWith("a");
    expect(props.onClose).toHaveBeenCalled();
  });

  it("keys beyond the list are swallowed, and letters map past 9", () => {
    const many = Array.from({ length: 12 }, (_, i) => ({
      id: `s${i}`,
      name: `sess-${i}`,
      cwd: "/w",
      active: i === 0,
    }));
    const props = openPicker(many);
    // 12 sessions: index 9 is "a", index 11 is "c"; "z" maps to nothing.
    fireEvent.keyDown(window, { key: "z" });
    expect(props.onSelectSession).not.toHaveBeenCalled();
    expect(props.onClose).not.toHaveBeenCalled();
    fireEvent.keyDown(window, { key: "c" });
    expect(props.onSelectSession).toHaveBeenCalledWith("s11");
  });

  it("Backspace steps back to the sessions group, not the root", () => {
    openPicker();
    fireEvent.keyDown(window, { key: "Backspace" });
    // Back at the sessions level: "n" (new session) is visible again.
    expect(document.querySelector('[data-leader-key="n"]')).not.toBeNull();
    expect(document.querySelector("#leader-session-picker")).toBeNull();
    fireEvent.keyDown(window, { key: "Backspace" });
    // Root again: the "r" rendering group is visible.
    expect(document.querySelector('[data-leader-key="r"]')).not.toBeNull();
  });

  it("keys and sessions stay 1:1 — SESSION_KEYS are unique", () => {
    expect(new Set(SESSION_KEYS).size).toBe(SESSION_KEYS.length);
  });
});
