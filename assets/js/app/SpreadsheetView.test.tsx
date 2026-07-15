import React from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const readXlsxFile = vi.fn();

vi.mock("read-excel-file/browser", () => ({
  default: (...args: unknown[]) => readXlsxFile(...args),
}));

import SpreadsheetView from "./SpreadsheetView";

beforeEach(() => {
  readXlsxFile.mockReset();
  vi.restoreAllMocks();
});

describe("SpreadsheetView", () => {
  it("searches and filters CSV rows without truncating the data", async () => {
    render(
      <SpreadsheetView
        path="/project/people.csv"
        csvContent={"name,team,score\nAda,Compiler,98\nAlan,Crypto,91\nGrace,Compiler,95\n"}
        wrap={false}
      />,
    );

    expect(await screen.findByRole("table")).toBeInTheDocument();
    expect(screen.getByText("3 rows · 3 columns")).toBeInTheDocument();

    fireEvent.change(screen.getByPlaceholderText("Search table…"), { target: { value: "Grace" } });
    expect(screen.getByText("Grace")).toBeInTheDocument();
    expect(screen.queryByText("Ada")).not.toBeInTheDocument();
    expect(screen.getByText("1 of 3 rows")).toBeInTheDocument();

    fireEvent.change(screen.getByPlaceholderText("Search table…"), { target: { value: "" } });
    fireEvent.change(screen.getByLabelText("Filter column"), { target: { value: "column-1" } });
    fireEvent.change(screen.getByPlaceholderText("Filter values…"), { target: { value: "Crypto" } });
    expect(screen.getByText("Alan")).toBeInTheDocument();
    expect(screen.queryByText("Grace")).not.toBeInTheDocument();
  });

  it("loads an XLSX file from the authenticated raw endpoint and switches sheets", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
    } as Response);
    readXlsxFile.mockResolvedValue([
      { sheet: "Summary", data: [["region", "sales"], ["North", 120]] },
      { sheet: "Details", data: [["owner", "status"], ["Lin", "Open"]] },
    ]);

    render(<SpreadsheetView path="/project/report.xlsx" wrap={true} />);

    expect(await screen.findByText("North")).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledWith(
      "/files/raw?path=%2Fproject%2Freport.xlsx",
      expect.objectContaining({ credentials: "same-origin" }),
    );
    expect(readXlsxFile).toHaveBeenCalledOnce();

    fireEvent.click(screen.getByRole("tab", { name: "Details" }));
    await waitFor(() => expect(screen.getByText("Lin")).toBeInTheDocument());
    expect(screen.queryByText("North")).not.toBeInTheDocument();
  });
});
