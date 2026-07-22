import { describe, expect, it } from "vitest";
import {
  basenameHost,
  breadcrumbsHost,
  dirnameHost,
  hostPathKey,
  isAbsoluteHost,
  joinHost,
  relativeHost,
  toFileUri,
} from "./hostPath";

describe("Windows host paths", () => {
  it("joins and navigates drive paths without converting them to POSIX roots", () => {
    expect(joinHost("C:\\Users\\Sea So", "项目")).toBe("C:\\Users\\Sea So\\项目");
    expect(dirnameHost("C:\\Users\\Sea So\\项目")).toBe("C:\\Users\\Sea So");
    expect(basenameHost("C:\\Users\\Sea So\\项目")).toBe("项目");
    expect(isAbsoluteHost("C:\\Users\\Sea So")).toBe(true);
  });

  it("keeps drive and UNC roots in breadcrumbs", () => {
    expect(breadcrumbsHost("C:\\Users\\Sea So")).toEqual([
      { label: "C:\\", path: "C:\\" },
      { label: "Users", path: "C:\\Users" },
      { label: "Sea So", path: "C:\\Users\\Sea So" },
    ]);
    expect(breadcrumbsHost("\\\\server\\share\\repo")[0]).toEqual({
      label: "\\\\server\\share",
      path: "\\\\server\\share",
    });
  });

  it("builds relative paths case-insensitively on Windows", () => {
    expect(relativeHost("C:\\Work\\Repo", "c:\\work\\Repo\\src\\main.ts")).toBe(
      "src\\main.ts",
    );
  });

  it.each([
    ["C:\\Work\\Repo", "c:/work/Repo/src/main.ts", "src/main.ts"],
    ["C:/Work/Repo", "c:\\work\\Repo\\src\\main.ts", "src\\main.ts"],
    ["\\\\Server\\Share\\Repo", "//server/share/Repo/src/a.ts", "src/a.ts"],
    ["//Server/Share/Repo", "\\\\server\\share\\Repo\\src\\a.ts", "src\\a.ts"],
  ])("builds relative paths across separator styles: %s -> %s", (from, to, expected) => {
    expect(relativeHost(from, to)).toBe(expected);
  });

  it.each([
    ["C:\\Work\\Repo", "D:/Work/Repo/src/main.ts"],
    ["\\\\Server\\Share\\Repo", "//server/other/Repo/src/a.ts"],
  ])("keeps targets on a different Windows root absolute: %s -> %s", (from, to) => {
    expect(relativeHost(from, to)).toBe(to);
  });

  it("encodes drive and UNC file URIs", () => {
    expect(toFileUri("C:\\Work Space\\中文.ts")).toBe(
      "file:///C:/Work%20Space/%E4%B8%AD%E6%96%87.ts",
    );
    expect(toFileUri("\\\\server\\share\\a b.txt")).toBe(
      "file://server/share/a%20b.txt",
    );
  });

  it("creates case-insensitive keys for Windows paths", () => {
    expect(hostPathKey("C:\\Work\\Dala\\")).toBe("c:/work/dala");
    expect(hostPathKey("c:/work/dala")).toBe("c:/work/dala");
    expect(hostPathKey("C:\\")).toBe("c:/");
    expect(hostPathKey("c:/")).toBe("c:/");
    expect(hostPathKey("/Work/Dala")).toBe("/Work/Dala");
  });
});

describe("POSIX host paths", () => {
  it("preserves current behavior", () => {
    expect(joinHost("/home/me", "src")).toBe("/home/me/src");
    expect(dirnameHost("/home/me/src")).toBe("/home/me");
    expect(relativeHost("/home/me", "/home/me/src/a.ts")).toBe("src/a.ts");
    expect(toFileUri("/home/me/a b.ts")).toBe("file:///home/me/a%20b.ts");
  });
});
