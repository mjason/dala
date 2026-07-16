import { beforeEach, describe, expect, it, vi } from "vitest";

const uploadMultipartFile = vi.fn();
vi.mock("./fileUpload", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./fileUpload")>()),
  uploadMultipartFile: (...args: unknown[]) => uploadMultipartFile(...args),
}));

import { pastedPathsText, uploadPastedFiles } from "./pastedFileUpload";

describe("pastedPathsText", () => {
  it("joins paths with spaces and keeps a trailing space", () => {
    expect(pastedPathsText(["/tmp/a.png"])).toBe("/tmp/a.png ");
    expect(pastedPathsText(["/tmp/a.png", "/tmp/b.txt"])).toBe("/tmp/a.png /tmp/b.txt ");
  });
});

describe("uploadPastedFiles", () => {
  beforeEach(() => uploadMultipartFile.mockReset());

  it("uploads sequentially through multipart and reports per-file progress", async () => {
    uploadMultipartFile
      .mockImplementationOnce(async (opts) => {
        opts.onProgress(1, 1);
        return { path: "/tmp/attachments/1/shot.png", size: 1 };
      })
      .mockImplementationOnce(async (opts) => {
        opts.onProgress(1, 1);
        return { path: "/tmp/attachments/2/note.txt", size: 1 };
      });
    const onError = vi.fn();
    const onProgress = vi.fn();

    const paths = await uploadPastedFiles(
      [
        new File(["x"], "shot.png", { type: "image/png" }),
        new File(["y"], "note.txt", { type: "text/plain" }),
      ],
      onError,
      { onProgress },
    );

    expect(paths).toEqual(["/tmp/attachments/1/shot.png", "/tmp/attachments/2/note.txt"]);
    expect(onError).not.toHaveBeenCalled();
    expect(uploadMultipartFile).toHaveBeenCalledTimes(2);
    expect(uploadMultipartFile.mock.calls[0][0]).toMatchObject({
      url: "/files/attachment",
      maxLabel: "512 MB",
    });
    expect(onProgress.mock.calls[0][0]).toMatchObject({
      fileName: "shot.png",
      fileIndex: 1,
      fileCount: 2,
      percent: 100,
    });
    expect(onProgress.mock.calls[1][0]).toMatchObject({
      fileName: "note.txt",
      fileIndex: 2,
    });
  });

  it("reports failed uploads and keeps the successful ones", async () => {
    uploadMultipartFile
      .mockRejectedValueOnce(new Error("disk full"))
      .mockResolvedValueOnce({ path: "/tmp/ok.txt", size: 1 });
    const onError = vi.fn();

    const paths = await uploadPastedFiles(
      [new File(["x"], "a.png"), new File(["y"], "b.txt")],
      onError,
    );

    expect(paths).toEqual(["/tmp/ok.txt"]);
    expect(onError).toHaveBeenCalledWith("disk full");
  });

  it("stops the sequential batch after cancellation without showing an error", async () => {
    const controller = new AbortController();
    uploadMultipartFile.mockImplementationOnce(async () => {
      controller.abort();
      throw new DOMException("Upload cancelled", "AbortError");
    });
    const onError = vi.fn();

    const paths = await uploadPastedFiles(
      [new File(["x"], "a.png"), new File(["y"], "b.png")],
      onError,
      { signal: controller.signal },
    );

    expect(paths).toEqual([]);
    expect(uploadMultipartFile).toHaveBeenCalledTimes(1);
    expect(onError).not.toHaveBeenCalled();
  });
});
