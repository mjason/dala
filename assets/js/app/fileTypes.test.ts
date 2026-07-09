import { describe, expect, it } from "vitest";
import { previewKind, rawFileUrl } from "./fileTypes";

describe("previewKind", () => {
  it("detects images", () => {
    expect(previewKind("photo.PNG")).toBe("image");
    expect(previewKind("logo.svg")).toBe("image");
    expect(previewKind("pic.jpeg")).toBe("image");
  });

  it("detects json / csv / html", () => {
    expect(previewKind("package.json")).toBe("json");
    expect(previewKind("data.csv")).toBe("csv");
    expect(previewKind("data.TSV")).toBe("csv");
    expect(previewKind("index.html")).toBe("html");
    expect(previewKind("page.htm")).toBe("html");
  });

  it("falls back to text", () => {
    expect(previewKind("mix.exs")).toBe("text");
    expect(previewKind("README")).toBe("text");
    expect(previewKind(".zshrc")).toBe("text");
  });
});

describe("rawFileUrl", () => {
  it("encodes the path", () => {
    expect(rawFileUrl("/home/mj/my file.html")).toBe(
      "/files/raw?path=%2Fhome%2Fmj%2Fmy+file.html",
    );
  });

  it("adds the download flag", () => {
    expect(rawFileUrl("/a.bin", true)).toBe("/files/raw?path=%2Fa.bin&download=1");
  });
});
