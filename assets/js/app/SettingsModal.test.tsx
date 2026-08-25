import React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { I18nProvider } from "./i18n";

// jsdom ships no scroll engine; the modal resets its body scroll on tab change.
if (typeof Element.prototype.scrollTo !== "function") {
  Element.prototype.scrollTo = () => {};
}

// meta is server-rendered; the modal only needs these to exist.
vi.mock("./meta", () => ({
  authEnabled: false,
  userEmail: null,
  socketToken: null,
  serverVersion: null,
}));

// Keep the heavy setting panels out of this unit — only the tab strip matters.
vi.mock("./settings/AppearanceSection", () => ({ default: () => null }));
vi.mock("./settings/NotificationsSection", () => ({ default: () => null }));
vi.mock("./settings/ShortcutsSection", () => ({ default: () => null }));
vi.mock("./settings/SpeechSection", () => ({ default: () => null }));
vi.mock("./settings/PromptOptimizerSection", () => ({ default: () => <div id="prompt-optimizer-section" /> }));
vi.mock("./settings/McpSection", () => ({ default: () => <div id="mcp-section" /> }));

vi.mock("../ash_rpc", () => ({
  closeSession: vi.fn(),
  deleteSession: vi.fn(),
  renameSession: vi.fn(),
  restartSession: vi.fn(),
  setScrollbackLimit: vi.fn(),
}));

import SettingsModal from "./SettingsModal";

const session = {
  id: "11111111-1111-1111-1111-111111111111",
  name: "test",
  shell: "zsh",
  cwd: "/home/mj",
  status: "running" as const,
  exitCode: null,
  scrollbackLimit: 10_000,
  ephemeral: false,
  parentId: null,
  position: 0,
  group: null,
  insertedAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T00:00:00.000000Z",
};

function renderModal() {
  return render(
    <I18nProvider>
      <SettingsModal
        session={session}
        onClose={() => {}}
        onDeleted={() => {}}
        onError={() => {}}
      />
    </I18nProvider>,
  );
}

afterEach(cleanup);

describe("SettingsModal tabs", () => {
  it("shows the short reference and copies the canonical session id", async () => {
    const clipboard = vi.fn().mockResolvedValue(undefined);
    (window as typeof window & { __DALA_CLIPBOARD__?: (text: string) => Promise<void> })
      .__DALA_CLIPBOARD__ = clipboard;

    const { container } = renderModal();
    const button = container.querySelector("#session-reference-copy") as HTMLElement;
    expect(button.textContent).toContain("#111111");
    expect(button.textContent).toContain(session.id);

    fireEvent.click(button);
    await waitFor(() => expect(clipboard).toHaveBeenCalledWith(session.id));
    delete (window as typeof window & { __DALA_CLIPBOARD__?: unknown }).__DALA_CLIPBOARD__;
  });

  it("always shows the MCP tab (enablement is a runtime toggle inside it)", () => {
    const { container } = renderModal();
    expect(container.querySelector('[data-settings-tab="mcp"]')).not.toBeNull();
  });

  it("renders the full always-present tab strip", () => {
    const { container } = renderModal();
    for (const key of ["session", "appearance", "shortcuts", "voice", "prompt", "mcp"]) {
      expect(container.querySelector(`[data-settings-tab="${key}"]`)).not.toBeNull();
    }
  });

  it("selecting the prompt tab shows the prompt optimizer section", () => {
    const { container } = renderModal();
    fireEvent.click(container.querySelector('[data-settings-tab="prompt"]') as HTMLElement);
    expect(container.querySelector("#prompt-optimizer-section")).not.toBeNull();
  });

  it("selecting the MCP tab shows the MCP section", () => {
    const { container } = renderModal();
    fireEvent.click(container.querySelector('[data-settings-tab="mcp"]') as HTMLElement);
    expect(container.querySelector("#mcp-section")).not.toBeNull();
  });
});

describe("the tab-reset effect must not adopt scrollTo's return value", () => {
  // Real reproduction of a blank screen: something in the page makes
  // `Element.scrollTo` return a value — a smooth-scroll polyfill or browser
  // extension returns a Promise, and jsdom's own stub above returns undefined
  // only because this file says so. An effect written as a bare expression
  // hands whatever that call returns straight to React as its cleanup
  // function, and React then calls it: "destroy is not a function", the whole
  // <SettingsModal> subtree unmounts, the screen goes white.
  //
  // React's warning names the case ("or returned a Promise") but nothing
  // enforces it, so the guarantee lives here instead.
  const scrollToReturning = (value: unknown) => {
    const original = Element.prototype.scrollTo;
    Element.prototype.scrollTo = function scrollTo() {
      return value;
    } as unknown as typeof Element.prototype.scrollTo;
    return () => {
      Element.prototype.scrollTo = original;
    };
  };

  it("survives a scrollTo that returns a Promise", async () => {
    const restore = scrollToReturning(Promise.resolve());
    const errors: unknown[] = [];
    const spy = vi.spyOn(console, "error").mockImplementation((...args) => {
      errors.push(args[0]);
    });

    try {
      const { container } = renderModal();
      // Mounted, and still mounted after the effects have run and (in
      // StrictMode) been torn down once.
      expect(container.querySelector("#settings-body")).not.toBeNull();

      // Changing tabs re-runs the effect, which is where the bad cleanup from
      // the previous run would be invoked.
      const appearance = container.querySelector(
        '[data-settings-tab="appearance"]',
      ) as HTMLElement;
      fireEvent.click(appearance);
      expect(container.querySelector("#settings-body")).not.toBeNull();

      const complaints = errors
        .map((entry) => String(entry))
        .filter((entry) => /must not return anything|destroy is not a function/.test(entry));
      expect(complaints, complaints.join("\n")).toEqual([]);
    } finally {
      spy.mockRestore();
      restore();
    }
  });

  it("survives a scrollTo that returns any other truthy value", () => {
    const restore = scrollToReturning(42);
    try {
      const { container } = renderModal();
      expect(container.querySelector("#settings-body")).not.toBeNull();
    } finally {
      restore();
    }
  });
});
