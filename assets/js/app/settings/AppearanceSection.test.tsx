import React from "react";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n";
import { ThemeProvider } from "../theme";
import AppearanceSection from "./AppearanceSection";

beforeEach(() => {
  localStorage.clear();
  vi.stubGlobal(
    "matchMedia",
    vi.fn().mockReturnValue({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    } as unknown as MediaQueryList),
  );
});

describe("AppearanceSection theme selector", () => {
  it("switches the complete application theme immediately", async () => {
    const user = userEvent.setup();
    render(
      <ThemeProvider>
        <I18nProvider>
          <AppearanceSection />
        </I18nProvider>
      </ThemeProvider>,
    );

    await user.click(screen.getByRole("button", { name: "Light" }));

    expect(document.documentElement.dataset.theme).toBe("light");
    expect(localStorage.getItem("phx:theme")).toBe("light");
    expect(screen.getByRole("button", { name: "Light" })).toHaveAttribute(
      "aria-pressed",
      "true",
    );
  });
});
