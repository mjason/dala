import { describe, expect, it } from "vitest";
import { buildGitDecorations, gitDecorationForPath } from "./gitDecorations";
import type { Status } from "./gitPanel/types";

function status(files: Status["files"], root = "/repo"): Status {
  return { repo: true, root, branch: "main", files, ignored: [] };
}

describe("buildGitDecorations", () => {
  it("decorates files and every parent directory with absolute paths", () => {
    const result = buildGitDecorations(
      status([
        { path: "lib/dala/app.ex", status: " M", staged: false, unstaged: true },
        { path: "README.md", status: "??", staged: false, unstaged: true },
      ]),
    );

    expect(result.entries.get("/repo/lib/dala/app.ex")).toMatchObject({ label: "M", tone: "modified" });
    expect(result.entries.get("/repo/lib/dala")).toMatchObject({ label: "•", tone: "modified" });
    expect(result.entries.get("/repo/lib")).toMatchObject({ label: "•", tone: "modified" });
    expect(result.entries.get("/repo/README.md")).toMatchObject({ label: "U", tone: "untracked" });
  });

  it("uses the strongest descendant tone for a folder", () => {
    const result = buildGitDecorations(
      status([
        { path: "src/new.ex", status: "??", staged: false, unstaged: true },
        { path: "src/gone.ex", status: " D", staged: false, unstaged: true },
        { path: "src/conflict.ex", status: "UU", staged: true, unstaged: true },
      ]),
    );

    expect(result.entries.get("/repo/src")).toMatchObject({ label: "•", tone: "conflict" });
    expect(result.entries.get("/repo/src/gone.ex")).toMatchObject({ label: "D", tone: "deleted" });
    expect(result.entries.get("/repo/src/conflict.ex")).toMatchObject({ label: "!", tone: "conflict" });
  });

  it("joins paths correctly when the repository root is slash", () => {
    const result = buildGitDecorations(
      status([{ path: "tmp/a", status: "A ", staged: true, unstaged: false }], "/"),
    );
    expect(result.entries.has("/tmp/a")).toBe(true);
    expect(result.entries.has("//tmp/a")).toBe(false);
  });

  it("decorates ignored files and collapsed directories without marking their parents", () => {
    const snapshot = status([]);
    snapshot.ignored = ["coverage", "tmp/debug.log"];
    const decorations = buildGitDecorations(snapshot);

    expect(decorations.entries.get("/repo/coverage")).toEqual({
      label: "I",
      title: "Git ignored",
      tone: "ignored",
    });
    expect(decorations.entries.get("/repo/tmp/debug.log")?.tone).toBe("ignored");
    expect(decorations.entries.has("/repo/tmp")).toBe(false);
  });

  it("inherits ignored-directory styling while preserving exact Git states", () => {
    const snapshot = status([
      { path: "vendor/keep.txt", status: " M", staged: false, unstaged: true },
    ]);
    snapshot.ignored = ["vendor"];
    const decorations = buildGitDecorations(snapshot);

    expect(gitDecorationForPath(decorations, "/repo/vendor/cache/data.bin")?.tone).toBe(
      "ignored",
    );
    expect(gitDecorationForPath(decorations, "/repo/vendor/keep.txt")?.tone).toBe("modified");
    expect(gitDecorationForPath(decorations, "/repo/README.md")).toBeUndefined();
  });
});
