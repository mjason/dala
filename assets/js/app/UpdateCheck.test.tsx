import * as Octane from "octane";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, waitFor } from "@octanejs/testing-library";
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

describe("UpdateCheck activation status", () => {
  it("shows a rollback reported by the restarted server", async () => {
    rpc.checkUpdate.mockResolvedValue(
      info({ updateState: "rolled_back", updateMessage: "Rolled back to v0.25.11" }),
    );
    renderCheck();

    await waitFor(() =>
      expect(document.querySelector("#update-error")?.textContent).toContain("Rolled back"),
    );
  });

  it("shows the helper's final success status", async () => {
    rpc.checkUpdate.mockResolvedValue(
      info({ updateState: "succeeded", updateMessage: "Activated v0.25.12" }),
    );
    renderCheck();

    await waitFor(() =>
      expect(document.querySelector("#update-status")?.textContent).toContain("Activated"),
    );
  });
});
