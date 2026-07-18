import { RangeSetBuilder, type Extension } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import type { IGrammar, IRawGrammar, StateStack } from "vscode-textmate";
import { INITIAL, Registry } from "vscode-textmate";
import { createOnigScanner, createOnigString, loadWASM } from "vscode-oniguruma";
import { rawFileUrl } from "../fileTypes";
import { colors } from "./theme";

/**
 * TextMate grammar highlighting for the editor/viewer: user-supplied
 * `.tmLanguage.json` grammars (global uploads or project `dala.jsonc`
 * entries — see Dala.SyntaxGrammars) run on the real vscode-textmate +
 * oniguruma engine and paint as CodeMirror decorations.
 *
 * The decorations carry INLINE colors so they win over any base Lezer
 * highlighting — the CM language stays loaded for indentation and comment
 * metadata, TextMate owns the pixels.
 */

export type GrammarInfo = {
  path: string;
  scopeName: string;
  name: string;
  extensions: string[];
  source: string;
};

// ---------------------------------------------------------------- oniguruma

// The wasm engine loads once per page, and only when a grammar is actually
// used — sessions without custom grammars never pay the ~460 KB.
let onigLibPromise: Promise<{
  createOnigScanner: typeof createOnigScanner;
  createOnigString: typeof createOnigString;
}> | null = null;

function onigLib() {
  onigLibPromise ??= fetch("/wasm/onig.wasm")
    .then((response) => {
      if (!response.ok) throw new Error(`onig.wasm: HTTP ${response.status}`);
      return response.arrayBuffer();
    })
    .then(async (buffer) => {
      await loadWASM(buffer);
      return { createOnigScanner, createOnigString };
    });
  return onigLibPromise;
}

// ----------------------------------------------------------------- grammars

// Bundled base grammars: extensions we can tokenize with TextMate when the
// user has INJECTION grammars targeting them (MagicPython for .py). Without
// injections these files keep their Lezer highlighting.
const BUNDLED_BASES: Record<string, { ext: string; url: string }> = {
  "source.python": { ext: ".py", url: "/grammars/python.tmLanguage.json" },
};

const rawGrammarCache = new Map<string, Promise<IRawGrammar | null>>();

function fetchRawGrammar(key: string, url: string): Promise<IRawGrammar | null> {
  const cached = rawGrammarCache.get(key);
  if (cached) return cached;
  const promise = fetch(url)
    .then(async (response) => {
      if (!response.ok) throw new Error(`grammar ${url}: HTTP ${response.status}`);
      return JSON.parse(await response.text()) as IRawGrammar;
    })
    .catch(() => null);
  rawGrammarCache.set(key, promise);
  return promise;
}

/** Injection grammars declare where they apply themselves
 * (`injectionSelector`); the registry hands them to every base grammar and
 * the selector gates the actual placement. */
async function injectionScopes(infos: GrammarInfo[]): Promise<string[]> {
  const out: string[] = [];
  for (const info of infos) {
    const raw = await fetchRawGrammar(info.path, rawFileUrl(info.path));
    if (raw && (raw as { injectionSelector?: string }).injectionSelector) out.push(info.scopeName);
  }
  return out;
}

const grammarCache = new Map<string, Promise<IGrammar | null>>();

/** Load `scope` in a registry that can also resolve every OTHER configured
 * grammar (and the bundled bases) — required for injections. */
function loadGrammarScoped(scope: string, infos: GrammarInfo[]): Promise<IGrammar | null> {
  const cacheKey = `${scope}::${infos.map((g) => g.path).join("|")}`;
  const cached = grammarCache.get(cacheKey);
  if (cached) return cached;

  const promise = (async () => {
    const injections = await injectionScopes(infos);
    const registry = new Registry({
      onigLib: onigLib(),
      loadGrammar: async (scopeName) => {
        const bundled = BUNDLED_BASES[scopeName];
        if (bundled) return fetchRawGrammar(scopeName, bundled.url);
        const info = infos.find((g) => g.scopeName === scopeName);
        if (!info) return null;
        return fetchRawGrammar(info.path, rawFileUrl(info.path));
      },
      getInjections: (scopeName) =>
        // Only bases receive injections (an injection injecting into another
        // injection is out of scope); each grammar's own injectionSelector
        // decides where inside the base it actually applies.
        scopeName === scope ? injections : [],
    });
    return registry.loadGrammar(scope);
  })().catch(() => null);

  grammarCache.set(cacheKey, promise);
  return promise;
}

/** Drop cached grammars so an updated upload takes effect on next open. */
export function clearGrammarCache() {
  grammarCache.clear();
  rawGrammarCache.clear();
}

// -------------------------------------------------------------- scope → css

// Most-specific scope wins: token scopes are ordered outermost → innermost,
// so we scan from the end. Colors mirror the Lezer highlight style in
// theme.ts, keeping both engines on one palette.
const SCOPE_STYLES: [prefix: string, style: string][] = [
  ["comment", `color:${colors.comment};font-style:italic`],
  ["punctuation.definition.comment", `color:${colors.comment};font-style:italic`],
  ["string", `color:${colors.string}`],
  ["constant.numeric", `color:${colors.number}`],
  ["constant.language", `color:${colors.number}`],
  ["constant.character", `color:${colors.type}`],
  ["constant", `color:${colors.number}`],
  ["keyword", `color:${colors.keyword}`],
  ["storage", `color:${colors.keyword}`],
  ["entity.name.function", `color:${colors.title}`],
  ["support.function", `color:${colors.title}`],
  ["entity.name.type", `color:${colors.type}`],
  ["entity.name.class", `color:${colors.type}`],
  ["entity.name.namespace", `color:${colors.type}`],
  ["entity.name.tag", `color:${colors.keyword}`],
  ["entity.other.attribute-name", `color:${colors.number}`],
  ["support.type", `color:${colors.type}`],
  ["support.class", `color:${colors.type}`],
  ["variable.language", `color:${colors.keyword}`],
  ["variable.parameter", `color:${colors.fg}`],
  ["markup.heading", `color:${colors.title};font-weight:600`],
  ["markup.bold", "font-weight:600"],
  ["markup.italic", "font-style:italic"],
  ["invalid", `color:${colors.danger}`],
];

export function styleForScopes(scopes: readonly string[]): string | null {
  for (let i = scopes.length - 1; i >= 0; i--) {
    const scope = scopes[i];
    for (const [prefix, style] of SCOPE_STYLES) {
      if (scope === prefix || scope.startsWith(prefix + ".")) return style;
    }
  }
  return null;
}

// ------------------------------------------------------------- CM extension

// Pathological lines are carried through untokenized (state passes along),
// so one minified line cannot stall the editor.
const MAX_TOKENIZED_LINE = 10_000;
const TOKENIZE_TIME_LIMIT_MS = 50;

/** The grammar matching a filename, by extension (case-insensitive). */
export function grammarForFile(filename: string, infos: GrammarInfo[]): GrammarInfo | null {
  const lower = filename.toLowerCase();
  return infos.find((g) => g.extensions.some((ext) => lower.endsWith(ext.toLowerCase()))) ?? null;
}

/**
 * Builds the highlighting extension for a file, or null when no configured
 * grammar claims it (grammar body fetched + engine booted lazily).
 */
export async function textmateExtension(
  filename: string,
  infos: GrammarInfo[],
): Promise<Extension | null> {
  const info = grammarForFile(filename, infos);
  if (info) {
    const grammar = await loadGrammarScoped(info.scopeName, infos);
    if (!grammar) return null;
    return tmHighlight(grammar);
  }

  // No standalone grammar claims the file — but injection grammars might
  // (a DSL inside Python strings): tokenize with the bundled base so the
  // injections have something to inject into.
  const lower = filename.toLowerCase();
  const baseScope = Object.keys(BUNDLED_BASES).find((scope) =>
    lower.endsWith(BUNDLED_BASES[scope].ext),
  );
  if (!baseScope) return null;
  if ((await injectionScopes(infos)).length === 0) return null;
  const grammar = await loadGrammarScoped(baseScope, infos);
  if (!grammar) return null;
  return tmHighlight(grammar);
}

function tmHighlight(grammar: IGrammar): Extension {
  const plugin = ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      // states[n] = tokenizer state BEFORE line n (1-based); states[1] = INITIAL.
      private states: StateStack[] = [];

      constructor(readonly view: EditorView) {
        this.states[1] = INITIAL;
        this.decorations = this.build(view);
      }

      update(update: ViewUpdate) {
        if (update.docChanged) {
          // Invalidate from the first changed line: everything after it may
          // have shifted lines or changed state.
          let firstChanged = update.state.doc.lines + 1;
          update.changes.iterChangedRanges((_fromA, _toA, fromB) => {
            firstChanged = Math.min(firstChanged, update.state.doc.lineAt(fromB).number);
          });
          this.states.length = Math.max(2, firstChanged);
        }
        if (update.docChanged || update.viewportChanged) {
          this.decorations = this.build(update.view);
        }
      }

      private stateBefore(lineNumber: number): StateStack {
        const doc = this.view.state.doc;
        let known = Math.min(this.states.length - 1, lineNumber);
        while (this.states[known] === undefined && known > 1) known--;

        for (let n = known; n < lineNumber; n++) {
          const text = doc.line(n).text;
          this.states[n + 1] =
            text.length > MAX_TOKENIZED_LINE
              ? this.states[n]
              : grammar.tokenizeLine(text, this.states[n], TOKENIZE_TIME_LIMIT_MS).ruleStack;
        }
        return this.states[lineNumber];
      }

      private build(view: EditorView): DecorationSet {
        const builder = new RangeSetBuilder<Decoration>();
        const doc = view.state.doc;

        for (const range of view.visibleRanges) {
          let line = doc.lineAt(range.from);
          for (;;) {
            if (line.text.length <= MAX_TOKENIZED_LINE) {
              const result = grammar.tokenizeLine(
                line.text,
                this.stateBefore(line.number),
                TOKENIZE_TIME_LIMIT_MS,
              );
              this.states[line.number + 1] = result.ruleStack;
              for (const token of result.tokens) {
                const style = styleForScopes(token.scopes);
                if (style && token.endIndex > token.startIndex) {
                  builder.add(
                    line.from + token.startIndex,
                    line.from + Math.min(token.endIndex, line.length),
                    Decoration.mark({ attributes: { style } }),
                  );
                }
              }
            } else {
              this.states[line.number + 1] = this.stateBefore(line.number);
            }
            if (line.to >= range.to || line.number >= doc.lines) break;
            line = doc.line(line.number + 1);
          }
        }
        return builder.finish();
      }
    },
    { decorations: (instance) => instance.decorations },
  );

  return plugin;
}

// ------------------------------------------------------------ file resolver

import { syntaxGrammars } from "../../ash_rpc";
import { call } from "../rpc";

/**
 * One-stop resolver for editors: asks the server which grammars apply to
 * an absolute path (project dala.jsonc + global uploads) and builds the
 * extension when one claims the file.
 */
export async function textmateForFile(path: string): Promise<Extension | null> {
  try {
    const result = await call<{ globalDir: string; grammars: GrammarInfo[] }>(syntaxGrammars, {
      input: { path },
      fields: ["globalDir", "grammars"] as never,
    });
    if (!result.ok || result.data.grammars.length === 0) return null;
    return await textmateExtension(path, result.data.grammars);
  } catch {
    return null;
  }
}
