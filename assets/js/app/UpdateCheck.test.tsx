import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, waitFor } from "@testing-library/react";
import UpdateCheck from "./UpdateCheck";
import { I18nProvider } from "./i18n";

const rpc = vi.hoisted(() => ({ checkUpdate: vi.fn(), applyUpdate: vi.fn() }));

vi.mock("../ash_rpc", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  ...rpc,
}));

vi.mock("./meta", () => ({ serverVersion: "0.25.11" }));

const info = (overrides: Record<string, unknown> = {}) => ({
  success: true,
  data: {
    enabled: true,
    current: "0.25.11",
    latest: "0.25.11",
    tag: "v0.25.11",
    updateAvailable: false,
    notesUrl: null,
    legacyEnvConfig: false,
    ...overrides,
  },
});

beforeEach(() => {
  vi.clearAllMocks();
});

function renderCheck() {
  return render(
    <I18nProvider>
      <UpdateCheck />
    </I18nProvider>,
  );
}

describe("UpdateCheck config-migration nudge", () => {
  it("legacy env mode shows the migration notice linking to the guide", async () => {
    rpc.checkUpdate.mockResolvedValue(info({ legacyEnvConfig: true }));
    renderCheck();
    await waitFor(() =>
      expect(document.querySelector("#config-migrate-notice")).not.toBeNull(),
    );
    const link = document.querySelector<HTMLAnchorElement>("#config-migrate-notice")!;
    expect(link.href).toContain("config-migration");
  });

  it("config-file installs see no notice", async () => {
    rpc.checkUpdate.mockResolvedValue(info());
    renderCheck();
    await waitFor(() => expect(rpc.checkUpdate).toHaveBeenCalled());
    expect(document.querySelector("#config-migrate-notice")).toBeNull();
  });
});
