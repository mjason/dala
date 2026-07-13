import { describe, expect, it } from "vitest";
import { LanguageDescription } from "@codemirror/language";
import { languageRegistry } from "./languages";

describe("jsonc language support", () => {
  it("dala.jsonc resolves to the JSONC description", () => {
    const match = LanguageDescription.matchFilename(languageRegistry, "dala.jsonc");
    expect(match?.name).toBe("JSONC");
  });

  it("tsconfig.json resolves to JSONC too (comments are legal there)", () => {
    const match = LanguageDescription.matchFilename(languageRegistry, "tsconfig.json");
    expect(match?.name).toBe("JSONC");
  });

  it("comments and trailing commas parse without error nodes", async () => {
    const match = LanguageDescription.matchFilename(languageRegistry, "dala.jsonc")!;
    const support = await match.load();
    const doc = [
      "{",
      '  // line comment',
      '  "speech": { "prompt": "你好" }, /* block */',
      '  "lsp": {},',
      "}",
    ].join("\n");
    const tree = support.language.parser.parse(doc);
    let errors = 0;
    tree.iterate({
      enter: (node) => {
        if (node.type.isError) errors++;
      },
    });
    expect(errors).toBe(0);
  });

  it("the strict-JSON failure mode is gone: a comment no longer poisons the parse", async () => {
    const match = LanguageDescription.matchFilename(languageRegistry, "x.jsonc")!;
    const support = await match.load();
    const tree = support.language.parser.parse('// header\n{ "a": 1 }');
    let errors = 0;
    tree.iterate({
      enter: (node) => {
        if (node.type.isError) errors++;
      },
    });
    expect(errors).toBe(0);
  });
});
