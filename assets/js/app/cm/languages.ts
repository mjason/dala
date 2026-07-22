import { LanguageDescription, LanguageSupport } from "@codemirror/language";
import { languages as builtin } from "@codemirror/language-data";
import type { Extension } from "@codemirror/state";
import { basenameHost } from "../hostPath";

/**
 * Language registry: CodeMirror's built-in descriptions (each grammar is
 * lazy-loaded as its own chunk on first use) plus Elixir/HEEx, which the
 * registry does not ship.
 */

const elixirDescription = LanguageDescription.of({
  name: "Elixir",
  alias: ["elixir", "ex", "exs", "iex"],
  extensions: ["ex", "exs"],
  filename: /^mix\.lock$/,
  load: async () => {
    const { elixir } = await import("codemirror-lang-elixir");
    return elixir();
  },
});

const heexDescription = LanguageDescription.of({
  name: "HEEx",
  alias: ["heex", "eex", "leex"],
  extensions: ["heex", "eex", "leex"],
  load: async () => {
    // No dedicated HEEx grammar; HTML gets the markup right.
    const { html } = await import("@codemirror/lang-html");
    return html();
  },
});

const jsoncDescription = LanguageDescription.of({
  name: "JSONC",
  alias: ["jsonc"],
  extensions: ["jsonc"],
  filename: /^(tsconfig|jsconfig)\.json$/,
  load: async () => {
    // A real JSONC Lezer grammar: comments and trailing commas are first-
    // class tokens (the strict JSON grammar marked them as parse errors,
    // which broke highlighting after the first comment in dala.jsonc).
    const { jsonc } = await import("@platformos/lang-jsonc");
    return jsonc();
  },
});

export const languageRegistry: LanguageDescription[] = [
  elixirDescription,
  heexDescription,
  jsoncDescription,
  ...builtin,
];

export function languageFor(filename: string): LanguageDescription | null {
  return LanguageDescription.matchFilename(languageRegistry, basenameHost(filename));
}

/** Loads the language support for a filename; null when unknown. */
export async function languageExtension(filename: string): Promise<Extension | null> {
  const description = languageFor(filename);
  if (!description) return null;

  try {
    return await description.load();
  } catch {
    return null;
  }
}

/** Loads a language by a markdown-fence style name ("js", "python", …). */
export async function languageByName(name: string): Promise<LanguageSupport | null> {
  const description = LanguageDescription.matchLanguageName(languageRegistry, name, true);
  if (!description) return null;

  try {
    return await description.load();
  } catch {
    return null;
  }
}
