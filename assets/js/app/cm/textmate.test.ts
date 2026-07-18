import { describe, expect, it } from "vitest";
import { grammarForFile, styleForScopes, type GrammarInfo } from "./textmate";

const info = (over: Partial<GrammarInfo>): GrammarInfo => ({
  path: "/g/x.json",
  scopeName: "source.x",
  name: "X",
  extensions: [".x"],
  source: "global",
  ...over,
});

describe("grammarForFile", () => {
  it("matches by extension, case-insensitively, first hit wins", () => {
    const project = info({ path: "/p/a.json", extensions: [".py"], source: "project" });
    const global = info({ path: "/g/b.json", extensions: [".PY"] });
    expect(grammarForFile("/src/App.PY", [project, global])).toBe(project);
    expect(grammarForFile("/src/app.rb", [project, global])).toBeNull();
  });
});

describe("styleForScopes", () => {
  it("prefers the most specific (innermost) scope", () => {
    const style = styleForScopes(["source.python", "string.quoted", "keyword.control"]);
    expect(style).toContain("color:");
    // innermost keyword wins over the outer string scope
    expect(style).toBe(styleForScopes(["keyword.control"]));
  });

  it("matches prefixes on dot boundaries only", () => {
    expect(styleForScopes(["keywordish.custom"])).toBeNull();
    expect(styleForScopes(["keyword.operator.arithmetic"])).not.toBeNull();
  });

  it("returns null for unknown scopes", () => {
    expect(styleForScopes(["source.python", "meta.function-call"])).toBeNull();
  });
});

describe("styleForScopes — DSL injection vocabulary", () => {
  it("a $variable inside a Python string stands out from the string", () => {
    const scopes = [
      "source.python",
      "string.quoted.double.python",
      "meta.embedded.dark-magician-dsl",
      "variable.other.dsl",
    ];
    expect(styleForScopes(scopes)).not.toBe(styleForScopes(["source.python", "string.quoted.double.python"]));
    expect(styleForScopes(scopes)).toContain("color");
  });

  it("the $ sigil and DSL function/operator/constant scopes all resolve", () => {
    for (const scope of [
      "punctuation.definition.variable.dsl",
      "support.function.dsl",
      "keyword.operator.dsl",
      "constant.numeric.dsl",
      "constant.language.dsl",
    ]) {
      expect(styleForScopes(["source.python", "string.quoted.double.python", scope])).toBeTruthy();
    }
  });
});
