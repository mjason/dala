import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import csharp from "highlight.js/lib/languages/csharp";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import elixir from "highlight.js/lib/languages/elixir";
import erlang from "highlight.js/lib/languages/erlang";
import go from "highlight.js/lib/languages/go";
import ini from "highlight.js/lib/languages/ini";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import kotlin from "highlight.js/lib/languages/kotlin";
import lua from "highlight.js/lib/languages/lua";
import makefile from "highlight.js/lib/languages/makefile";
import markdown from "highlight.js/lib/languages/markdown";
import php from "highlight.js/lib/languages/php";
import python from "highlight.js/lib/languages/python";
import ruby from "highlight.js/lib/languages/ruby";
import rust from "highlight.js/lib/languages/rust";
import scss from "highlight.js/lib/languages/scss";
import sql from "highlight.js/lib/languages/sql";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";

hljs.registerLanguage("bash", bash);
hljs.registerLanguage("c", c);
hljs.registerLanguage("cpp", cpp);
hljs.registerLanguage("csharp", csharp);
hljs.registerLanguage("css", css);
hljs.registerLanguage("diff", diff);
hljs.registerLanguage("dockerfile", dockerfile);
hljs.registerLanguage("elixir", elixir);
hljs.registerLanguage("erlang", erlang);
hljs.registerLanguage("go", go);
hljs.registerLanguage("ini", ini);
hljs.registerLanguage("java", java);
hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("json", json);
hljs.registerLanguage("kotlin", kotlin);
hljs.registerLanguage("lua", lua);
hljs.registerLanguage("makefile", makefile);
hljs.registerLanguage("markdown", markdown);
hljs.registerLanguage("php", php);
hljs.registerLanguage("python", python);
hljs.registerLanguage("ruby", ruby);
hljs.registerLanguage("rust", rust);
hljs.registerLanguage("scss", scss);
hljs.registerLanguage("sql", sql);
hljs.registerLanguage("swift", swift);
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("xml", xml);
hljs.registerLanguage("yaml", yaml);

const EXT_TO_LANGUAGE: Record<string, string> = {
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  c: "c",
  h: "c",
  cc: "cpp",
  cpp: "cpp",
  cxx: "cpp",
  hpp: "cpp",
  cs: "csharp",
  css: "css",
  diff: "diff",
  patch: "diff",
  ex: "elixir",
  exs: "elixir",
  heex: "elixir",
  erl: "erlang",
  hrl: "erlang",
  go: "go",
  ini: "ini",
  toml: "ini",
  conf: "ini",
  java: "java",
  js: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  jsx: "javascript",
  json: "json",
  jsonc: "json",
  kt: "kotlin",
  kts: "kotlin",
  lua: "lua",
  md: "markdown",
  markdown: "markdown",
  php: "php",
  py: "python",
  rb: "ruby",
  rs: "rust",
  scss: "scss",
  sass: "scss",
  sql: "sql",
  swift: "swift",
  ts: "typescript",
  tsx: "typescript",
  mts: "typescript",
  html: "xml",
  htm: "xml",
  xml: "xml",
  svg: "xml",
  vue: "xml",
  yaml: "yaml",
  yml: "yaml",
};

const NAME_TO_LANGUAGE: Record<string, string> = {
  dockerfile: "dockerfile",
  makefile: "makefile",
  gnumakefile: "makefile",
  ".zshrc": "bash",
  ".bashrc": "bash",
  ".profile": "bash",
  ".gitignore": "ini",
  ".env": "ini",
};

/** highlight.js language for a file name, or null when unknown. */
export function detectLanguage(fileName: string): string | null {
  const base = fileName.split("/").pop()?.toLowerCase() ?? "";
  if (NAME_TO_LANGUAGE[base]) return NAME_TO_LANGUAGE[base];

  const ext = base.includes(".") ? base.split(".").pop()! : "";
  return EXT_TO_LANGUAGE[ext] ?? null;
}

/** Highlighted HTML for code, or null when the language is unknown. */
export function highlightCode(code: string, fileName: string): string | null {
  const language = detectLanguage(fileName);
  if (!language) return null;

  try {
    return hljs.highlight(code, { language }).value;
  } catch {
    return null;
  }
}

/** Highlighted HTML for a unified diff. */
export function highlightDiff(diffText: string): string {
  try {
    return hljs.highlight(diffText, { language: "diff" }).value;
  } catch {
    return diffText.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
}
