import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import PromptStash from "./PromptStash";
import { I18nProvider } from "./i18n";

const rpc = vi.hoisted(() => ({
  listPrompts: vi.fn(),
  stashPrompt: vi.fn(),
  archivePrompt: vi.fn(),
  restorePrompt: vi.fn(),
  deletePrompt: vi.fn(),
}));

vi.mock("../ash_rpc", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  ...rpc,
}));

const ok = (data: unknown) => Promise.resolve({ success: true, data });

function renderStash(value = "", setValue = vi.fn(), onError = vi.fn()) {
  render(
    <I18nProvider>
      <PromptStash value={value} setValue={setValue} onError={onError} />
    </I18nProvider>,
  );
  return { setValue, onError };
}

beforeEach(() => {
  vi.clearAllMocks();
  rpc.listPrompts.mockReturnValue(ok([]));
  rpc.stashPrompt.mockReturnValue(ok({ id: "p9" }));
  rpc.archivePrompt.mockReturnValue(ok({ id: "p1" }));
  rpc.restorePrompt.mockReturnValue(ok({ id: "p2" }));
  rpc.deletePrompt.mockReturnValue(ok({ id: "p1" }));
});

describe("PromptStash", () => {
  it("opens the panel and shows the empty state", async () => {
    renderStash();
    fireEvent.click(document.querySelector("#prompt-stash-button")!);
    await waitFor(() => expect(document.querySelector("#prompt-stash-panel")).not.toBeNull());
    await screen.findByText(/Nothing stashed yet/);
  });

  it("stashes the current composer input and clears it", async () => {
    const setValue = vi.fn();
    renderStash("my idea", setValue);
    fireEvent.click(document.querySelector("#prompt-stash-button")!);
    await waitFor(() => expect(document.querySelector("#stash-current-button")).not.toBeNull());
    fireEvent.click(document.querySelector("#stash-current-button")!);
    await waitFor(() =>
      expect(rpc.stashPrompt).toHaveBeenCalledWith(
        expect.objectContaining({ input: { content: "my idea" } }),
      ),
    );
    expect(setValue).toHaveBeenCalledWith("");
  });

  it("clicking a stashed prompt inserts it and archives it", async () => {
    rpc.listPrompts.mockReturnValue(ok([{ id: "p1", content: "do the thing", status: "stashed" }]));
    const setValue = vi.fn();
    renderStash("", setValue);
    fireEvent.click(document.querySelector("#prompt-stash-button")!);
    await waitFor(() => expect(document.querySelector('[data-prompt-row="p1"]')).not.toBeNull());
    fireEvent.click(document.querySelector('[data-prompt-row="p1"]')!);
    expect(setValue).toHaveBeenCalledWith("do the thing");
    await waitFor(() =>
      expect(rpc.archivePrompt).toHaveBeenCalledWith(expect.objectContaining({ identity: "p1" })),
    );
    // Panel closes after inserting.
    expect(document.querySelector("#prompt-stash-panel")).toBeNull();
  });

  it("appends below existing composer text instead of overwriting", async () => {
    rpc.listPrompts.mockReturnValue(ok([{ id: "p1", content: "extra", status: "stashed" }]));
    const setValue = vi.fn();
    renderStash("already typed", setValue);
    fireEvent.click(document.querySelector("#prompt-stash-button")!);
    await waitFor(() => expect(document.querySelector('[data-prompt-row="p1"]')).not.toBeNull());
    fireEvent.click(document.querySelector('[data-prompt-row="p1"]')!);
    expect(setValue).toHaveBeenCalledWith("already typed\nextra");
  });

  it("archived entries insert without re-archiving, and can be restored or deleted", async () => {
    rpc.listPrompts.mockReturnValue(ok([{ id: "p2", content: "old one", status: "archived" }]));
    const setValue = vi.fn();
    renderStash("", setValue);
    fireEvent.click(document.querySelector("#prompt-stash-button")!);
    await waitFor(() => expect(document.querySelector('[data-prompt-row="p2"]')).not.toBeNull());

    fireEvent.click(document.querySelector('[data-prompt-restore="p2"]')!);
    await waitFor(() =>
      expect(rpc.restorePrompt).toHaveBeenCalledWith(expect.objectContaining({ identity: "p2" })),
    );

    fireEvent.click(document.querySelector('[data-prompt-row="p2"]')!);
    expect(setValue).toHaveBeenCalledWith("old one");
    expect(rpc.archivePrompt).not.toHaveBeenCalled();
  });
});
