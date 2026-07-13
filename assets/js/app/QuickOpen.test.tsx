import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, waitFor } from "@testing-library/react";
import { I18nProvider } from "./i18n";

const listFiles = vi.fn();

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  listFiles: (...args: unknown[]) => listFiles(...args),
}));

import QuickOpen from "./QuickOpen";

function filesResult(files: string[]) {
  return { success: true, data: { root: "/proj", files, truncated: false } };
}

function renderQuickOpen(onPick: (path: string) => void = () => {}) {
  return render(
    <I18nProvider>
      <QuickOpen root="/proj" onPick={onPick} onClose={() => {}} onError={() => {}} />
    </I18nProvider>,
  );
}

async function search(query: string) {
  const input = document.querySelector("#quick-open-input") as HTMLInputElement;
  fireEvent.change(input, { target: { value: query } });
  await waitFor(() => {
    expect(document.querySelector("[data-quick-path]")).not.toBeNull();
  });
}

/** The row's rendered path text and its mint-highlighted substring. */
function renderedRow() {
  const row = document.querySelector("[data-quick-path]")!;
  const spans = Array.from(row.querySelectorAll("span span"));
  return {
    text: spans.map((s) => s.textContent).join(""),
    highlighted: spans
      .filter((s) => s.className.includes("text-mint"))
      .map((s) => s.textContent)
      .join(""),
  };
}

describe("QuickOpen highlighting", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders NFD filenames in NFC and aligns the highlight", async () => {
    const nfd = "docs/cafe\u0301.md"; // decomposed é (e + combining acute)
    listFiles.mockResolvedValue(filesResult([nfd]));
    renderQuickOpen();

    await search("café"); // composed é, as keyboards produce
    const { text, highlighted } = renderedRow();
    expect(text).toBe(nfd.normalize("NFC"));
    expect(highlighted).toBe("café");
  });

  it("keeps emoji intact and highlights the right characters around them", async () => {
    listFiles.mockResolvedValue(filesResult(["docs/🚀rocket.md"]));
    renderQuickOpen();

    await search("rocket");
    const { text, highlighted } = renderedRow();
    expect(text).toBe("docs/🚀rocket.md");
    expect(highlighted).toBe("rocket");
    // No span may hold a lone surrogate half (that renders as �).
    const spans = Array.from(document.querySelectorAll("[data-quick-path] span span"));
    for (const span of spans) {
      expect(span.textContent!.isWellFormed()).toBe(true);
    }
  });

  it("picks the ORIGINAL path bytes, not the NFC display form", async () => {
    const nfd = "docs/cafe\u0301.md";
    const picked: string[] = [];
    listFiles.mockResolvedValue(filesResult([nfd]));
    renderQuickOpen((p) => picked.push(p));

    await search("café");
    fireEvent.click(document.querySelector("[data-quick-path]")!);
    expect(picked).toEqual([`/proj/${nfd}`]);
  });
});
