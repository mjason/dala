import { describe, expect, it } from "vitest";
import { parseDiff, unquoteGitPath, toSplitRows } from "./diffParse";

const SAMPLE = `diff --git a/lib/app.ex b/lib/app.ex
index 111..222 100644
--- a/lib/app.ex
+++ b/lib/app.ex
@@ -1,3 +1,3 @@
 line one
-old two
+new two
 line three
`;

describe("parseDiff", () => {
  it("extracts files, paths and counts", () => {
    const { files } = parseDiff(SAMPLE);
    expect(files).toHaveLength(1);
    expect(files[0].newPath).toBe("lib/app.ex");
    expect(files[0].additions).toBe(1);
    expect(files[0].deletions).toBe(1);
  });

  it("assigns line numbers per side", () => {
    const { files } = parseDiff(SAMPLE);
    const lines = files[0].hunks[0].lines;
    expect(lines[0]).toMatchObject({ kind: "ctx", oldNo: 1, newNo: 1 });
    expect(lines[1]).toMatchObject({ kind: "del", oldNo: 2, newNo: null, text: "old two" });
    expect(lines[2]).toMatchObject({ kind: "add", oldNo: null, newNo: 2, text: "new two" });
    expect(lines[3]).toMatchObject({ kind: "ctx", oldNo: 3, newNo: 3 });
  });

  it("detects binary files", () => {
    const { files } = parseDiff(
      "diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n",
    );
    expect(files[0].binary).toBe(true);
  });

  it("handles renames", () => {
    const { files } = parseDiff(
      "diff --git a/old.txt b/new.txt\nrename from old.txt\nrename to new.txt\n",
    );
    expect(files[0].oldPath).toBe("old.txt");
    expect(files[0].newPath).toBe("new.txt");
  });

  it("keeps a git-show preamble (commit message / stat)", () => {
    const withPreamble = `commit abc123
Author: Someone
    my message

 lib/app.ex | 2 +-
${SAMPLE}`;
    const { preamble, files } = parseDiff(withPreamble);
    expect(preamble).toContain("my message");
    expect(files).toHaveLength(1);
  });

  it("parses multiple files", () => {
    const two = SAMPLE + `diff --git a/b.ex b/b.ex\n--- a/b.ex\n+++ b/b.ex\n@@ -1 +1 @@\n-x\n+y\n`;
    expect(parseDiff(two).files).toHaveLength(2);
  });
});

describe("toSplitRows", () => {
  it("pairs deletions with additions and keeps context aligned", () => {
    const { files } = parseDiff(SAMPLE);
    const rows = toSplitRows(files[0].hunks[0]);
    // ctx, (del|add paired), ctx
    expect(rows[0]).toMatchObject({ left: { text: "line one" }, right: { text: "line one" } });
    expect(rows[1].left?.text).toBe("old two");
    expect(rows[1].right?.text).toBe("new two");
    expect(rows[2]).toMatchObject({ left: { text: "line three" } });
  });

  it("leaves a gap when adds and dels are unbalanced", () => {
    const diff = `diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1,2 @@\n-one\n+one\n+two\n`;
    const rows = toSplitRows(parseDiff(diff).files[0].hunks[0]);
    expect(rows[0]).toMatchObject({ left: { text: "one" }, right: { text: "one" } });
    expect(rows[1].left).toBeNull();
    expect(rows[1].right?.text).toBe("two");
  });
});

describe("git quoted paths (non-ASCII filenames)", () => {
  it("decodes C-quoted octal escapes back to UTF-8", () => {
    expect(unquoteGitPath('"\\346\\226\\207.txt"')).toBe("\u6587.txt");
    expect(unquoteGitPath("plain/path.py")).toBe("plain/path.py");
    expect(unquoteGitPath('"with\\ttab"')).toBe("with\ttab");
  });

  it("parses a libgit2 patch for an untracked Chinese-named file", () => {
    // Verbatim NIF output for strategies/黄果树/做空.py
    const text =
      'diff --git "a/strategies/\\351\\273\\204\\346\\236\\234\\346\\240\\221/\\345\\201\\232\\347\\251\\272.py" "b/strategies/\\351\\273\\204\\346\\236\\234\\346\\240\\221/\\345\\201\\232\\347\\251\\272.py"\n' +
      "new file mode 100644\n" +
      "index 0000000..83db48f\n" +
      "--- /dev/null\n" +
      '+++ "b/strategies/\\351\\273\\204\\346\\236\\234\\346\\240\\221/\\345\\201\\232\\347\\251\\272.py"\n' +
      "@@ -0,0 +1,3 @@\n" +
      "+line1\n" +
      "+line2\n" +
      "+line3";

    const parsed = parseDiff(text);
    expect(parsed.files).toHaveLength(1);
    const file = parsed.files[0];
    expect(file.newPath).toBe("strategies/\u9ec4\u679c\u6811/\u505a\u7a7a.py");
    expect(file.additions).toBe(3);
    expect(file.hunks[0].lines.map((l) => l.text)).toEqual(["line1", "line2", "line3"]);
  });
});
