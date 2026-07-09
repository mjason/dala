import { describe, expect, it } from "vitest";
import { detectLanguage, highlightCode, highlightDiff } from "./highlight";

describe("detectLanguage", () => {
  it("maps common extensions", () => {
    expect(detectLanguage("app.ts")).toBe("typescript");
    expect(detectLanguage("server.ex")).toBe("elixir");
    expect(detectLanguage("main.rs")).toBe("rust");
    expect(detectLanguage("script.PY")).toBe("python");
    expect(detectLanguage("index.html")).toBe("xml");
    expect(detectLanguage("config.yml")).toBe("yaml");
  });

  it("maps well-known file names", () => {
    expect(detectLanguage("Dockerfile")).toBe("dockerfile");
    expect(detectLanguage("Makefile")).toBe("makefile");
    expect(detectLanguage(".zshrc")).toBe("bash");
  });

  it("works with full paths", () => {
    expect(detectLanguage("/home/mj/dev/lib/foo.exs")).toBe("elixir");
  });

  it("returns null for unknown types", () => {
    expect(detectLanguage("notes.xyz")).toBeNull();
    expect(detectLanguage("README")).toBeNull();
  });
});

describe("highlightCode", () => {
  it("produces highlighted HTML for known languages", () => {
    const html = highlightCode('const x = "hi";', "a.ts");
    expect(html).toContain("hljs-");
    expect(html).toContain("hljs-string");
  });

  it("returns null for unknown languages", () => {
    expect(highlightCode("whatever", "a.unknownext")).toBeNull();
  });
});

describe("highlightDiff", () => {
  it("marks additions and deletions", () => {
    const html = highlightDiff("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old line\n+new line\n");
    expect(html).toContain("hljs-addition");
    expect(html).toContain("hljs-deletion");
  });
});
