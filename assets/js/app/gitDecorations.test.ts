import { describe, expect, it } from "vitest";
import { buildGitDecorations } from "./gitDecorations";
import type { Status } from "./gitPanel/types";

function status(files: Status["files"], root = "/repo"): Status {
  return { repo: true, root, branch: "main", files };
}

describe("buildGitDecorations", () => {
  it("decorates files and every parent directory with absolute paths", () => {
    const result = buildGitDecorations(
      status([
        { path: "lib/dala/app.ex", status: " M", staged: false, unstaged: true },
        { path: "README.md", status: "??", staged: false, unstaged: true },
      ]),
    );

    expect(result.get("/repo/lib/dala/app.ex")).toMatchObject({ label: "M", tone: "modified" });
    expect(result.get("/repo/lib/dala")).toMatchObject({ label: "•", tone: "modified" });
    expect(result.get("/repo/lib")).toMatchObject({ label: "•", tone: "modified" });
    expect(result.get("/repo/README.md")).toMatchObject({ label: "U", tone: "added" });
  });

  it("uses the strongest descendant tone for a folder", () => {
    const result = buildGitDecorations(
      status([
        { path: "src/new.ex", status: "??", staged: false, unstaged: true },
        { path: "src/gone.ex", status: " D", staged: false, unstaged: true },
        { path: "src/conflict.ex", status: "UU", staged: true, unstaged: true },
      ]),
    );

    expect(result.get("/repo/src")).toMatchObject({ label: "•", tone: "conflict" });
    expect(result.get("/repo/src/gone.ex")).toMatchObject({ label: "D", tone: "deleted" });
    expect(result.get("/repo/src/conflict.ex")).toMatchObject({ label: "!", tone: "conflict" });
  });

  it("joins paths correctly when the repository root is slash", () => {
    const result = buildGitDecorations(
      status([{ path: "tmp/a", status: "A ", staged: true, unstaged: false }], "/"),
    );
    expect(result.has("/tmp/a")).toBe(true);
    expect(result.has("//tmp/a")).toBe(false);
  });
});
