import React from "react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { I18nProvider } from "../i18n";
import ShortcutsSection from "./ShortcutsSection";
import { KEY_GUIDE } from "../keyGuide";

beforeEach(() => {
  localStorage.clear();
});

afterEach(cleanup);

function renderSection() {
  return render(
    <I18nProvider>
      <ShortcutsSection />
    </I18nProvider>,
  );
}

describe("ShortcutsSection key guide", () => {
  it("renders the TUI key guide below the rebindable shortcuts", () => {
    const { container } = renderSection();
    expect(container.querySelector("#key-guide")).not.toBeNull();
    // Reads after (below) the dala shortcut list + reset button.
    const reset = container.querySelector("#shortcuts-reset-all");
    const guide = container.querySelector("#key-guide");
    expect(reset).not.toBeNull();
    expect(
      reset!.compareDocumentPosition(guide!) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });

  it("shows every guide group and its key combos", () => {
    renderSection();
    for (const group of KEY_GUIDE) {
      expect(screen.getByText(group.app)).toBeTruthy();
      for (const row of group.rows) {
        // Repeated combos (Ctrl+O ×2) appear more than once — getAllByText.
        for (const key of row.keys) {
          expect(screen.getAllByText(key).length).toBeGreaterThan(0);
        }
      }
    }
  });
});
