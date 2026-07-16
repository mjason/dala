import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { I18nProvider } from "../i18n";

// theme.ts apply-layer: spy on the live preview + restore-on-cancel.
const applyCustomTokens = vi.fn();
const applyTheme = vi.fn();
vi.mock("../theme", () => ({
  applyCustomTokens: (...a: unknown[]) => applyCustomTokens(...a),
  applyTheme: (...a: unknown[]) => applyTheme(...a),
}));

// RPC: create/update outcomes are controllable; `call` (real) wraps them.
const createTheme = vi.fn();
const updateTheme = vi.fn();
vi.mock("../../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  createTheme: (...a: unknown[]) => createTheme(...a),
  updateTheme: (...a: unknown[]) => updateTheme(...a),
}));

import ThemeEditor, { type ThemeDraft } from "./ThemeEditor";

const ok = (data: unknown) => ({ success: true, data });

function renderEditor(draft: ThemeDraft, overrides: Record<string, unknown> = {}) {
  const props = { draft, onClose: vi.fn(), onSaved: vi.fn(), onError: vi.fn(), ...overrides };
  const utils = render(
    <I18nProvider>
      <ThemeEditor {...(props as React.ComponentProps<typeof ThemeEditor>)} />
    </I18nProvider>,
  );
  return { ...utils, props };
}

/** The tokens map from the most recent applyCustomTokens preview call. */
const lastPreviewTokens = () =>
  applyCustomTokens.mock.calls.at(-1)?.[0] as Record<string, string>;
const lastPreviewBase = () => applyCustomTokens.mock.calls.at(-1)?.[1] as string;

beforeEach(() => {
  localStorage.clear();
  applyCustomTokens.mockClear();
  applyTheme.mockClear();
  createTheme.mockReset();
  updateTheme.mockReset();
});

afterEach(cleanup);

describe("ThemeEditor live preview", () => {
  it("shows Git state tokens in their own editor group", () => {
    const { container } = renderEditor({ name: "Draft", base: "dark", tokens: {} });
    expect(container.querySelector("[data-theme-group='git']")).not.toBeNull();
    expect(container.querySelector("#theme-hex-gitAdded")).not.toBeNull();
    expect(container.querySelector("#theme-hex-gitConflict")).not.toBeNull();
  });

  it("editing a colour previews the updated sparse token map", () => {
    const { container } = renderEditor({ name: "Draft", base: "dark", tokens: {} });
    const hex = container.querySelector("#theme-hex-bg0") as HTMLInputElement;
    fireEvent.change(hex, { target: { value: "#123456" } });
    expect(lastPreviewTokens()).toEqual({ bg0: "#123456" });
    expect(lastPreviewBase()).toBe("dark");
  });

  it("reset removes an override from the previewed map", () => {
    const { container } = renderEditor({ name: "Draft", base: "dark", tokens: { bg0: "#123456" } });
    expect(lastPreviewTokens()).toEqual({ bg0: "#123456" });
    fireEvent.click(container.querySelector("[data-reset-token='bg0']")!);
    expect(lastPreviewTokens()).toEqual({});
    expect((container.querySelector("#theme-hex-bg0") as HTMLInputElement).value).toBe("");
  });
});

describe("ThemeEditor base toggle", () => {
  it("re-seeds the placeholder defaults from the other palette", () => {
    const { container } = renderEditor({ name: "Draft", base: "dark", tokens: {} });
    const hex = () => container.querySelector("#theme-hex-bg0") as HTMLInputElement;
    expect(hex().placeholder).toBe("#0b0c0e"); // dark default
    fireEvent.click(container.querySelector("[data-theme-base='light']")!);
    expect(hex().placeholder).toBe("#fbfbfa"); // light default re-seeded
    expect(lastPreviewBase()).toBe("light");
  });
});

describe("ThemeEditor duplicate (fork)", () => {
  it("copies tokens into a new draft and saves via createTheme", async () => {
    createTheme.mockResolvedValue(ok({ id: "new-1" }));
    const { container, props } = renderEditor({
      id: "src-1",
      name: "Source",
      base: "dark",
      tokens: { bg0: "#111111" },
    });
    fireEvent.click(container.querySelector("#duplicate-theme-button")!);
    // Name gets the copy suffix; the source id is dropped so save is a create.
    expect((container.querySelector("#theme-name-input") as HTMLInputElement).value).toBe(
      "Source copy",
    );
    fireEvent.click(container.querySelector("#save-theme-button")!);
    await waitFor(() => expect(createTheme).toHaveBeenCalled());
    expect(updateTheme).not.toHaveBeenCalled();
    expect(createTheme.mock.calls[0][0].input).toMatchObject({
      name: "Source copy",
      base: "dark",
      tokens: { bg0: "#111111" },
    });
    expect(props.onSaved).toHaveBeenCalledWith("new-1", "dark", { bg0: "#111111" });
  });
});

describe("ThemeEditor save", () => {
  it("creates a new theme with sparse tokens + name", async () => {
    createTheme.mockResolvedValue(ok({ id: "new-2" }));
    const { container, props } = renderEditor({ name: "", base: "dark", tokens: {} });
    fireEvent.change(container.querySelector("#theme-name-input")!, {
      target: { value: "Midnight" },
    });
    // The ANSI group is collapsed by default — expand it to reach ansiRed.
    fireEvent.click(container.querySelector("[data-theme-group='ansi']")!);
    fireEvent.change(container.querySelector("#theme-hex-ansiRed")!, {
      target: { value: "#ff0000" },
    });
    fireEvent.click(container.querySelector("#save-theme-button")!);
    await waitFor(() => expect(createTheme).toHaveBeenCalled());
    expect(createTheme.mock.calls[0][0].input).toEqual({
      name: "Midnight",
      base: "dark",
      tokens: { ansiRed: "#ff0000" }, // only the one override — sparse
    });
    expect(props.onSaved).toHaveBeenCalledWith("new-2", "dark", { ansiRed: "#ff0000" });
  });

  it("updates an existing theme by identity", async () => {
    updateTheme.mockResolvedValue(ok({ id: "edit-1" }));
    const { container } = renderEditor({
      id: "edit-1",
      name: "Existing",
      base: "light",
      tokens: { fg: "#222222" },
    });
    fireEvent.click(container.querySelector("#save-theme-button")!);
    await waitFor(() => expect(updateTheme).toHaveBeenCalled());
    expect(createTheme).not.toHaveBeenCalled();
    const arg = updateTheme.mock.calls[0][0];
    expect(arg.identity).toBe("edit-1");
    expect(arg.input).toMatchObject({ name: "Existing", base: "light", tokens: { fg: "#222222" } });
  });

  it("rejects an empty name without hitting the server", () => {
    const { container, props } = renderEditor({ name: "   ", base: "dark", tokens: {} });
    fireEvent.click(container.querySelector("#save-theme-button")!);
    expect(createTheme).not.toHaveBeenCalled();
    expect(props.onError).toHaveBeenCalled();
  });
});

describe("ThemeEditor cancel", () => {
  it("restores the previously-selected theme via applyTheme", () => {
    const { container, props } = renderEditor({ name: "Draft", base: "dark", tokens: {} });
    fireEvent.click(container.querySelector("#theme-editor")!.parentElement!); // backdrop
    expect(applyTheme).toHaveBeenCalled();
    expect(props.onClose).toHaveBeenCalled();
  });
});
