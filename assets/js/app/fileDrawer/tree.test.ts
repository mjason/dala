import { describe, expect, it } from "vitest";
import { buildTreeRows, crumbs, join, relativePath } from "./tree";
import type { Entry, Listing } from "./tree";

const t = (key: string, params?: Record<string, string | number>) =>
  params ? `${key}:${JSON.stringify(params)}` : key;

const entry = (name: string, type = "file", size = 10): Entry => ({
  name,
  type,
  symlink: false,
  size,
  mtime: null,
});

describe("join", () => {
  it("joins against a normal directory", () => {
    expect(join("/proj", "src")).toBe("/proj/src");
  });

  it("does not double the slash at the filesystem root", () => {
    expect(join("/", "etc")).toBe("/etc");
  });
});

describe("relativePath", () => {
  it("walks down from the root", () => {
    expect(relativePath("/proj", "/proj/src/main.ex")).toBe("src/main.ex");
  });

  it("walks up with ..", () => {
    expect(relativePath("/proj/src", "/proj/mix.exs")).toBe("../mix.exs");
  });

  it("returns . for the root itself", () => {
    expect(relativePath("/proj", "/proj")).toBe(".");
  });
});

describe("crumbs", () => {
  it("returns a single segment for /", () => {
    expect(crumbs("/")).toEqual([{ label: "/", path: "/" }]);
  });

  it("accumulates paths per segment", () => {
    expect(crumbs("/a/b")).toEqual([
      { label: "/", path: "/" },
      { label: "a", path: "/a" },
      { label: "b", path: "/a/b" },
    ]);
  });
});

describe("buildTreeRows", () => {
  const root: Listing = {
    path: "/proj",
    parent: "/",
    entries: [entry("src", "directory"), entry(".env"), entry("mix.exs")],
  };

  it("returns nothing for a null root", () => {
    expect(buildTreeRows(null, {}, new Set(), false, t)).toEqual([]);
  });

  it("prepends the up-row and lists visible entries with a hidden note", () => {
    const rows = buildTreeRows(root, { "/proj": root.entries }, new Set(["/proj"]), false, t);
    expect(rows.map((r) => r.kind)).toEqual(["up", "dir", "file", "note"]);
    expect(rows[0]).toEqual({ kind: "up", path: "/" });
    expect(rows[1]).toMatchObject({ path: "/proj/src", depth: 0, parentDir: "/proj" });
    expect(rows[3]).toMatchObject({ id: "/proj:hidden" });
  });

  it("shows dotfiles when showHidden is on", () => {
    const rows = buildTreeRows(root, { "/proj": root.entries }, new Set(["/proj"]), true, t);
    expect(rows.some((r) => r.kind === "file" && r.path === "/proj/.env")).toBe(true);
    expect(rows.some((r) => r.kind === "note")).toBe(false);
  });

  it("recurses into expanded directories with increased depth", () => {
    const rows = buildTreeRows(
      root,
      { "/proj": root.entries, "/proj/src": [entry("main.ex")] },
      new Set(["/proj", "/proj/src"]),
      false,
      t,
    );
    const child = rows.find((r) => r.kind === "file" && r.path === "/proj/src/main.ex");
    expect(child).toMatchObject({ depth: 1, parentDir: "/proj/src" });
  });

  it("emits an empty-directory note", () => {
    const rows = buildTreeRows(
      root,
      { "/proj": root.entries, "/proj/src": [] },
      new Set(["/proj", "/proj/src"]),
      false,
      t,
    );
    expect(rows.some((r) => r.kind === "note" && r.id === "/proj/src:empty")).toBe(true);
  });
});
