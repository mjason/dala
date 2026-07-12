import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: vi.fn(() => ({ "x-csrf-token": "test-token" })),
  readFile: vi.fn(),
}));

import { readFile } from "../ash_rpc";
import { loadPreview } from "./loadPreview";

const readFileMock = vi.mocked(readFile);

function mockRead(result: unknown) {
  readFileMock.mockResolvedValue(result as never);
}

beforeEach(() => {
  readFileMock.mockReset();
});

describe("loadPreview", () => {
  it("serves images by URL without any RPC round-trip", async () => {
    const result = await loadPreview("shots/screen.png", 1234);

    expect(result).toEqual({
      ok: true,
      preview: { kind: "image", path: "shots/screen.png", size: 1234 },
    });
    expect(readFileMock).not.toHaveBeenCalled();
  });

  it("image WITHOUT a caller size asks the server instead of showing 0 bytes", async () => {
    mockRead({ success: true, data: { path: "shots/screen.png", size: 4321 } });

    const result = await loadPreview("shots/screen.png");

    expect(result).toEqual({
      ok: true,
      preview: { kind: "image", path: "shots/screen.png", size: 4321 },
    });
    // metadata only — the image bytes are served by URL, not RPC
    const args = readFileMock.mock.calls[0][0];
    expect(args.fields).not.toContain("content");
  });

  it("image size lookup failure still shows the preview (size 0)", async () => {
    mockRead({ success: false, errors: [{ message: "gone" }] });

    const result = await loadPreview("shots/screen.png");

    expect(result).toEqual({
      ok: true,
      preview: { kind: "image", path: "shots/screen.png", size: 0 },
    });
  });

  it("reads text files via RPC with CSRF headers", async () => {
    mockRead({
      success: true,
      data: { path: "/notes.txt", size: 5, truncated: false, binary: false, content: "hello" },
    });

    const result = await loadPreview("/notes.txt");

    expect(result).toEqual({
      ok: true,
      preview: {
        kind: "text",
        path: "/notes.txt",
        size: 5,
        truncated: false,
        content: "hello",
      },
    });
    expect(readFileMock).toHaveBeenCalledWith({
      input: { path: "/notes.txt" },
      fields: ["path", "size", "truncated", "binary", "content"],
      headers: { "x-csrf-token": "test-token" },
    });
  });

  it("keeps the extension-derived kind for structured text", async () => {
    mockRead({
      success: true,
      data: { path: "/conf.json", size: 2, truncated: false, binary: false, content: "{}" },
    });

    const result = await loadPreview("/conf.json");
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.preview.kind).toBe("json");
  });

  it("normalizes a null content to an empty string", async () => {
    mockRead({
      success: true,
      data: { path: "/empty.txt", size: 0, truncated: false, binary: false, content: null },
    });

    const result = await loadPreview("/empty.txt");
    expect(result.ok).toBe(true);
    if (result.ok && result.preview.kind === "text") {
      expect(result.preview.content).toBe("");
    }
  });

  it("flags truncated reads", async () => {
    mockRead({
      success: true,
      data: { path: "/big.log", size: 999, truncated: true, binary: false, content: "head" },
    });

    const result = await loadPreview("/big.log");
    expect(result.ok).toBe(true);
    if (result.ok && result.preview.kind === "text") {
      expect(result.preview.truncated).toBe(true);
    }
  });

  it("turns binary files into a binary preview using the server metadata", async () => {
    mockRead({
      success: true,
      data: { path: "/bin/tool", size: 4096, truncated: false, binary: true, content: null },
    });

    const result = await loadPreview("/bin/tool", 1);
    expect(result).toEqual({
      ok: true,
      preview: { kind: "binary", path: "/bin/tool", size: 4096 },
    });
  });

  it("surfaces the first RPC error message", async () => {
    mockRead({ success: false, errors: [{ message: "no such file" }, { message: "other" }] });

    expect(await loadPreview("/gone.txt")).toEqual({ ok: false, message: "no such file" });
  });

  it("returns a null message when the RPC error carries none", async () => {
    mockRead({ success: false, errors: [] });

    expect(await loadPreview("/gone.txt")).toEqual({ ok: false, message: null });
  });
});
