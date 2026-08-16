import * as Octane from "octane";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@octanejs/testing-library";
import { I18nProvider } from "../i18n";

const promptOptimizerSettings = vi.fn();
const setPromptOptimizerSettings = vi.fn();

vi.mock("../../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  promptOptimizerSettings: (...args: unknown[]) => promptOptimizerSettings(...args),
  setPromptOptimizerSettings: (...args: unknown[]) => setPromptOptimizerSettings(...args),
}));

import PromptOptimizerSection from "./PromptOptimizerSection";

const SETTINGS = {
  endpoint: "https://api.deepseek.com",
  model: "deepseek-v4-flash",
  prompt: "Fix mistakes without changing intent.",
  apiKeySet: true,
};

function renderSection() {
  return render(
    <I18nProvider>
      <PromptOptimizerSection />
    </I18nProvider>,
  );
}

afterEach(cleanup);

describe("PromptOptimizerSection", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    promptOptimizerSettings.mockResolvedValue({ success: true, data: SETTINGS });
    setPromptOptimizerSettings.mockResolvedValue({ success: true, data: SETTINGS });
  });

  it("loads server settings without receiving the API key", async () => {
    const { container } = renderSection();

    await waitFor(() => {
      expect(
        (container.querySelector("#prompt-optimizer-prompt-input") as HTMLTextAreaElement).value,
      ).toBe(SETTINGS.prompt);
    });

    const key = container.querySelector("#prompt-optimizer-api-key-input") as HTMLInputElement;
    expect(key.value).toBe("");
    expect(key.placeholder).toContain("configured");
  });

  it("saves only the field that lost focus", async () => {
    const { container } = renderSection();
    const endpoint = container.querySelector(
      "#prompt-optimizer-endpoint-input",
    ) as HTMLInputElement;
    await waitFor(() => expect(endpoint.value).toBe(SETTINGS.endpoint));

    fireEvent.input(endpoint, { target: { value: "https://proxy.test/v1" } });
    fireEvent.blur(endpoint);

    await waitFor(() => {
      expect(setPromptOptimizerSettings).toHaveBeenCalledWith(
        expect.objectContaining({ input: { endpoint: "https://proxy.test/v1" } }),
      );
    });
  });

  it("sends a new API key but never renders it back", async () => {
    const { container } = renderSection();
    const key = container.querySelector("#prompt-optimizer-api-key-input") as HTMLInputElement;
    await waitFor(() => expect(key.placeholder).toContain("configured"));

    fireEvent.input(key, { target: { value: "sk-new-secret" } });
    fireEvent.blur(key);

    await waitFor(() => {
      expect(setPromptOptimizerSettings).toHaveBeenCalledWith(
        expect.objectContaining({ input: { apiKey: "sk-new-secret" } }),
      );
      expect(key.value).toBe("");
    });
  });
});
