import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { I18nProvider } from "../i18n";

const GLOBAL = "00000000-0000-0000-0000-000000000000";

// The library comes from a hook; feed it a fixed list (no channel/socket).
const reload = vi.fn();
const useThemeLibrary = vi.fn();
vi.mock("../hooks/useThemeLibrary", () => ({
  useThemeLibrary: (...a: unknown[]) => useThemeLibrary(...a),
}));

// theme.ts apply-layer, all spied.
const saveThemeChoice = vi.fn();
const applyTheme = vi.fn();
const cacheCustomTheme = vi.fn();
const applyCustomTokens = vi.fn();
const loadThemeChoice = vi.fn(
  (..._a: unknown[]): { setting: string; customId: string | null } => ({
    setting: "system",
    customId: null,
  }),
);
const effectiveTheme = vi.fn((..._a: unknown[]) => "dark");
vi.mock("../theme", () => ({
  saveThemeChoice: (...a: unknown[]) => saveThemeChoice(...a),
  applyTheme: (...a: unknown[]) => applyTheme(...a),
  cacheCustomTheme: (...a: unknown[]) => cacheCustomTheme(...a),
  applyCustomTokens: (...a: unknown[]) => applyCustomTokens(...a),
  loadThemeChoice: (...a: unknown[]) => loadThemeChoice(...a),
  effectiveTheme: (...a: unknown[]) => effectiveTheme(...a),
}));

const deleteTheme = vi.fn();
const createTheme = vi.fn();
const updateTheme = vi.fn();
vi.mock("../../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  deleteTheme: (...a: unknown[]) => deleteTheme(...a),
  createTheme: (...a: unknown[]) => createTheme(...a),
  updateTheme: (...a: unknown[]) => updateTheme(...a),
}));

import AppearanceSection from "./AppearanceSection";

const THEMES = [
  { id: "c1", ownerId: GLOBAL, name: "Mine", base: "dark", builtin: false, tokens: { bg0: "#111111" } },
  { id: "b1", ownerId: GLOBAL, name: "Solarized Dark", base: "dark", builtin: true, tokens: { bg0: "#002b36" } },
];

function renderSection(themes = THEMES) {
  useThemeLibrary.mockReturnValue({ themes, reload });
  const onError = vi.fn();
  const utils = render(
    <I18nProvider>
      <AppearanceSection onError={onError} />
    </I18nProvider>,
  );
  return { ...utils, onError };
}

const q = (c: HTMLElement, sel: string) => c.querySelector(sel) as HTMLElement;

beforeEach(() => {
  localStorage.clear();
  reload.mockClear();
  saveThemeChoice.mockClear();
  applyTheme.mockClear();
  deleteTheme.mockReset();
  loadThemeChoice.mockReturnValue({ setting: "system", customId: null });
});

afterEach(cleanup);

describe("AppearanceSection theme library", () => {
  it("renders each theme as a terminal palette preview", () => {
    const { container } = renderSection();
    expect(container.querySelectorAll("[data-theme-terminal-preview]")).toHaveLength(2);
    expect(container.querySelectorAll("[data-theme-palette]")).toHaveLength(2);
    expect(container.querySelectorAll("[data-theme-ansi-swatch]")).toHaveLength(16);
    expect(container.querySelectorAll("[data-theme-git-preview]")).toHaveLength(2);
    expect(container.querySelectorAll("[data-theme-git-swatch]")).toHaveLength(14);
    expect(q(container, "[data-theme-terminal-preview='c1']").textContent).toContain("dala status");
  });

  it("selecting a custom chip saves {custom, id}, applies, and marks it pressed", () => {
    const { container } = renderSection();
    fireEvent.click(q(container, "[data-custom-theme-id='c1']"));
    expect(saveThemeChoice).toHaveBeenCalledWith("custom", "c1");
    expect(applyTheme).toHaveBeenCalled();
    expect(q(container, "[data-custom-theme-id='c1']").getAttribute("aria-pressed")).toBe("true");
  });

  it("selecting a built-in triad clears the custom selection", () => {
    const { container } = renderSection();
    fireEvent.click(q(container, "[data-custom-theme-id='c1']"));
    fireEvent.click(q(container, "[data-theme-setting='light']"));
    expect(saveThemeChoice).toHaveBeenLastCalledWith("light", null);
    expect(q(container, "[data-custom-theme-id='c1']").getAttribute("aria-pressed")).toBe("false");
    expect(q(container, "[data-theme-setting='light']").getAttribute("aria-pressed")).toBe("true");
  });

  it("built-in chips expose fork only; custom chips expose edit + delete", () => {
    const { container } = renderSection();
    expect(q(container, "[data-fork-theme-id='b1']")).not.toBeNull();
    expect(container.querySelector("[data-edit-theme-id='b1']")).toBeNull();
    expect(container.querySelector("[data-delete-theme-id='b1']")).toBeNull();
    expect(q(container, "[data-edit-theme-id='c1']")).not.toBeNull();
    expect(q(container, "[data-delete-theme-id='c1']")).not.toBeNull();
    expect(container.querySelector("[data-fork-theme-id='c1']")).toBeNull();
  });

  it("the new-theme button opens the editor on the current effective base", () => {
    const { container } = renderSection();
    expect(container.querySelector("#theme-editor")).toBeNull();
    fireEvent.click(q(container, "#new-theme-button"));
    expect(q(container, "#theme-editor")).not.toBeNull();
    expect(effectiveTheme).toHaveBeenCalled();
  });

  it("editing a custom chip opens the editor prefilled with its name", () => {
    const { container } = renderSection();
    fireEvent.click(q(container, "[data-edit-theme-id='c1']"));
    expect((q(container, "#theme-name-input") as HTMLInputElement).value).toBe("Mine");
  });

  it("deletes a custom theme after a confirm step", async () => {
    deleteTheme.mockResolvedValue({ success: true, data: {} });
    const { container } = renderSection();
    fireEvent.click(q(container, "[data-delete-theme-id='c1']")); // arm
    expect(deleteTheme).not.toHaveBeenCalled();
    fireEvent.click(q(container, "[data-delete-theme-id='c1']")); // confirm
    await waitFor(() => expect(deleteTheme).toHaveBeenCalled());
    expect(deleteTheme.mock.calls[0][0].identity).toBe("c1");
  });

  it("deleting the ACTIVE custom theme repaints via the system path, not just a state flip", async () => {
    loadThemeChoice.mockReturnValue({ setting: "custom", customId: "c1" });
    deleteTheme.mockResolvedValue({ success: true, data: {} });
    const { container } = renderSection();
    fireEvent.click(q(container, "[data-delete-theme-id='c1']")); // arm
    fireEvent.click(q(container, "[data-delete-theme-id='c1']")); // confirm
    await waitFor(() => expect(deleteTheme).toHaveBeenCalled());
    // chooseTheme("system"): persist + applyTheme (clears the custom overrides
    // and re-colours), so the app doesn't stay painted with the deleted theme.
    expect(saveThemeChoice).toHaveBeenCalledWith("system", null);
    expect(applyTheme).toHaveBeenCalled();
  });
});

describe("AppearanceSection segmented-control polish", () => {
  it("renders the theme triad as a recessed well (bg-bg2) with a raised pill (bg-bg0)", () => {
    const { container } = renderSection();
    const control = q(container, "#theme-setting-control");
    expect(control.className).toContain("bg-bg2");
    // system is selected by default → raised pill.
    const selected = q(container, "[data-theme-setting='system']");
    const unselected = q(container, "[data-theme-setting='light']");
    expect(selected.className).toContain("bg-bg0");
    expect(unselected.className).not.toContain("bg-bg0");
  });
});
