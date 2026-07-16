import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_UPLOAD_LIMITS, loadUploadLimits, UploadError, uploadMultipartFile } from "./fileUpload";

class FakeXMLHttpRequest {
  static instances: FakeXMLHttpRequest[] = [];

  upload: { onprogress: ((event: { loaded: number }) => void) | null } = { onprogress: null };
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onabort: (() => void) | null = null;
  status = 0;
  responseText = "";
  method = "";
  url = "";
  body: FormData | null = null;
  headers: Record<string, string> = {};

  constructor() {
    FakeXMLHttpRequest.instances.push(this);
  }

  open(method: string, url: string) {
    this.method = method;
    this.url = url;
  }

  setRequestHeader(name: string, value: string) {
    this.headers[name] = value;
  }

  send(body: FormData) {
    this.body = body;
  }

  abort() {
    this.onabort?.();
  }

  respond(status: number, body: object) {
    this.status = status;
    this.responseText = JSON.stringify(body);
    this.onload?.();
  }
}

describe("uploadMultipartFile", () => {
  beforeEach(() => {
    FakeXMLHttpRequest.instances = [];
    vi.stubGlobal("XMLHttpRequest", FakeXMLHttpRequest);
  });

  afterEach(() => vi.unstubAllGlobals());

  it("sends multipart data, reports progress and returns the server path", async () => {
    const file = new File(["hello"], "hello.txt", { type: "text/plain" });
    const onProgress = vi.fn();
    const pending = uploadMultipartFile({
      url: "/files/upload",
      file,
      fields: { dir: "/project" },
      maxBytes: 100,
      maxLabel: "100 B",
      onProgress,
    });

    const xhr = FakeXMLHttpRequest.instances[0];
    expect(xhr.method).toBe("POST");
    expect(xhr.url).toBe("/files/upload");
    expect(xhr.headers.Accept).toBe("application/json");
    expect(xhr.body?.get("dir")).toBe("/project");
    expect(xhr.body?.get("file")).toBe(file);

    xhr.upload.onprogress?.({ loaded: 3 });
    xhr.respond(200, { path: "/project/hello.txt", name: "hello.txt", size: 5 });

    await expect(pending).resolves.toEqual({
      path: "/project/hello.txt",
      name: "hello.txt",
      size: 5,
    });
    expect(onProgress).toHaveBeenNthCalledWith(1, 0, 5);
    expect(onProgress).toHaveBeenCalledWith(3, 5);
    expect(onProgress).toHaveBeenLastCalledWith(5, 5);
  });

  it("rejects oversized files before creating a request", async () => {
    const file = new File(["too large"], "large.bin");

    await expect(
      uploadMultipartFile({
        url: "/files/upload",
        file,
        maxBytes: 1,
        maxLabel: "1 B",
      }),
    ).rejects.toThrow("large.bin: file exceeds the 1 B limit");
    expect(FakeXMLHttpRequest.instances).toHaveLength(0);
  });

  it("surfaces the server's configured 413 message", async () => {
    const pending = uploadMultipartFile({
      url: "/files/attachment",
      file: new File(["x"], "x.bin"),
      maxBytes: 10,
      maxLabel: "10 B",
    });
    FakeXMLHttpRequest.instances[0].respond(413, {
      error: "terminal attachment is too large (max 4 MB per file)",
    });

    await expect(pending).rejects.toEqual(
      new UploadError("terminal attachment is too large (max 4 MB per file)"),
    );
  });

  it("aborts the active XHR through AbortSignal", async () => {
    const controller = new AbortController();
    const pending = uploadMultipartFile({
      url: "/files/upload",
      file: new File(["x"], "x.bin"),
      maxBytes: 10,
      maxLabel: "10 B",
      signal: controller.signal,
    });

    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
  });
});

describe("loadUploadLimits", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("uses the server's effective runtime limits", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(
        JSON.stringify({
          drawer_upload: { max_bytes: 4096, max_label: "4 KB" },
          browser_attachment: { max_bytes: 2048, max_label: "2 KB" },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(loadUploadLimits()).resolves.toEqual({
      drawerUpload: { maxBytes: 4096, maxLabel: "4 KB" },
      browserAttachment: { maxBytes: 2048, maxLabel: "2 KB" },
    });
    expect(fetchMock).toHaveBeenCalledWith("/files/limits", {
      cache: "no-store",
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
  });

  it("falls back to defaults when the limits endpoint is unavailable or malformed", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 200 })));
    await expect(loadUploadLimits()).resolves.toEqual(DEFAULT_UPLOAD_LIMITS);

    vi.stubGlobal("fetch", vi.fn(async () => new Response("unavailable", { status: 503 })));
    await expect(loadUploadLimits()).resolves.toEqual(DEFAULT_UPLOAD_LIMITS);
  });
});
