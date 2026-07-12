import { beforeEach, describe, expect, it, vi } from "vitest";

const savePastedFile = vi.fn();
vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  savePastedFile: (...args: unknown[]) => savePastedFile(...args),
}));

import { pastedPathsText, uploadPastedFiles } from "./pastedFileUpload";

describe("pastedPathsText", () => {
  it("joins paths with spaces and keeps a trailing space", () => {
    expect(pastedPathsText(["/tmp/a.png"])).toBe("/tmp/a.png ");
    expect(pastedPathsText(["/tmp/a.png", "/tmp/b.txt"])).toBe("/tmp/a.png /tmp/b.txt ");
  });
});

describe("uploadPastedFiles", () => {
  beforeEach(() => {
    savePastedFile.mockReset();
  });

  it("uploads each file and collects the returned paths", async () => {
    savePastedFile
      .mockResolvedValueOnce({ success: true, data: { path: "/tmp/dala-paste/paste-1.png" } })
      .mockResolvedValueOnce({ success: true, data: { path: "/tmp/dala-paste/paste-2.txt" } });
    const onError = vi.fn();

    const paths = await uploadPastedFiles(
      [
        new File(["x"], "shot.png", { type: "image/png" }),
        new File(["y"], "note.txt", { type: "text/plain" }),
      ],
      onError,
    );

    expect(paths).toEqual(["/tmp/dala-paste/paste-1.png", "/tmp/dala-paste/paste-2.txt"]);
    expect(onError).not.toHaveBeenCalled();
    expect(savePastedFile).toHaveBeenCalledTimes(2);
    expect(savePastedFile.mock.calls[0][0]).toMatchObject({ fields: ["path"] });
  });

  it("reports failed uploads and keeps the successful ones", async () => {
    savePastedFile
      .mockResolvedValueOnce({ success: false, errors: [{ message: "disk full" }] })
      .mockResolvedValueOnce({ success: true, data: { path: "/tmp/ok.txt" } });
    const onError = vi.fn();

    const paths = await uploadPastedFiles(
      [new File(["x"], "a.png"), new File(["y"], "b.txt")],
      onError,
    );

    expect(paths).toEqual(["/tmp/ok.txt"]);
    expect(onError).toHaveBeenCalledWith("disk full");
  });
});
