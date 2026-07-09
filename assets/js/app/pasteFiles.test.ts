import { describe, expect, it } from "vitest";
import { collectTransferFiles, fileToBase64, pasteName } from "./pasteFiles";

function makeTransfer(files: File[], withItems: boolean): DataTransfer {
  return {
    items: withItems
      ? files.map((file) => ({ kind: "file", getAsFile: () => file }))
      : { length: 0 },
    files,
  } as unknown as DataTransfer;
}

describe("collectTransferFiles", () => {
  const png = new File([new Uint8Array([1, 2, 3])], "shot.png", { type: "image/png" });

  it("returns empty for null transfers", () => {
    expect(collectTransferFiles(null)).toEqual([]);
  });

  it("collects files from clipboard items (paste)", () => {
    const dt = {
      items: [
        { kind: "string", getAsFile: () => null },
        { kind: "file", getAsFile: () => png },
      ],
      files: [],
    } as unknown as DataTransfer;
    expect(collectTransferFiles(dt)).toEqual([png]);
  });

  it("falls back to the files list (drop)", () => {
    expect(collectTransferFiles(makeTransfer([png], false))).toEqual([png]);
  });

  it("returns empty for text-only pastes", () => {
    const dt = {
      items: [{ kind: "string", getAsFile: () => null }],
      files: [],
    } as unknown as DataTransfer;
    expect(collectTransferFiles(dt)).toEqual([]);
  });
});

describe("fileToBase64", () => {
  it("round-trips file bytes", async () => {
    const bytes = new Uint8Array([137, 80, 78, 71, 0, 255]);
    const encoded = await fileToBase64(new File([bytes], "x.png", { type: "image/png" }));
    expect(Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0))).toEqual(bytes);
  });
});

describe("pasteName", () => {
  it("prefers the filename, falls back to mime, then png", () => {
    expect(pasteName(new File([""], "a.jpeg", { type: "image/jpeg" }))).toBe("a.jpeg");
    expect(pasteName(new File([""], "", { type: "image/webp" }))).toBe("image/webp");
    expect(pasteName(new File([""], "", { type: "" }))).toBe("png");
  });
});
