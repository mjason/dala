import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, waitFor } from "@testing-library/react";
import { I18nProvider } from "./i18n";

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  writeFile: vi.fn(),
}));
// Heavy viewers are irrelevant to the toolbar under test.
vi.mock("./CmCode", () => ({ default: () => <div data-testid="cmcode" /> }));
vi.mock("./CodeEditor", () => ({ default: () => <div data-testid="codeeditor" /> }));
vi.mock("./SpreadsheetView", () => ({ default: () => <div data-testid="sheet" /> }));
vi.mock("./LspDebug", () => ({ default: () => null }));

import FilePreview, { type Preview } from "./FilePreview";

const htmlPreview: Preview = {
  kind: "html",
  path: "/proj/report.html",
  size: 10,
  truncated: false,
  content: "<html></html>",
};

function renderPreview() {
  return render(
    <I18nProvider>
      <FilePreview preview={htmlPreview} onClose={() => {}} onError={() => {}} />
    </I18nProvider>,
  );
}

type W = Window & { dala?: { invoke: (cmd: string, args?: unknown) => Promise<unknown> } };

describe("FilePreview open-in-browser", () => {
  beforeEach(() => {
    delete (window as W).dala;
  });
  afterEach(() => {
    delete (window as W).dala;
  });

  it("plain web: a single open-in-browser link, no system-browser button", () => {
    renderPreview();
    expect(document.querySelector("#open-in-browser-button")).not.toBeNull();
    expect(document.querySelector("#open-in-system-browser-button")).toBeNull();
  });

  it("desktop client: a button group; the system button hands an ABSOLUTE http url to open_external", async () => {
    const invoke = vi.fn().mockResolvedValue(true);
    (window as W).dala = { invoke };
    renderPreview();

    // Both destinations offered.
    expect(document.querySelector("#open-in-browser-button")).not.toBeNull();
    const sys = document.querySelector("#open-in-system-browser-button");
    expect(sys).not.toBeNull();

    // Other app code may invoke the bridge too (shortcuts, notifications) —
    // assert on the open_external call specifically.
    const externals = () => invoke.mock.calls.filter(([cmd]) => cmd === "open_external");
    fireEvent.click(sys!);
    await waitFor(() => expect(externals()).toHaveLength(1));
    const [, args] = externals()[0] as [string, { url: string }];
    // Relative raw URL resolved against the page origin — main process only
    // accepts absolute http(s).
    expect(args.url).toMatch(/^https?:\/\//);
    expect(args.url).toContain(encodeURIComponent("/proj/report.html"));
  });
});
