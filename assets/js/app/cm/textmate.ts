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

const grammarCache = new Map<string, Promise<IGrammar | null>>();

function loadGrammarFor(info: GrammarInfo): Promise<IGrammar | null> {
  const cached = grammarCache.get(info.path);
  if (cached) return cached;

  const promise = (async () => {
    // One registry per grammar file. Cross-grammar includes (other scope
    // names) resolve to null — single-file grammars only, by design.
    const registry = new Registry({
      onigLib: onigLib(),
      loadGrammar: async (scopeName) => {
        if (scopeName !== info.scopeName) return null;
        const response = await fetch(rawFileUrl(info.path));
        if (!response.ok) throw new Error(`grammar ${info.path}: HTTP ${response.status}`);
        return JSON.parse(await response.text()) as IRawGrammar;
      },
    });
    return registry.loadGrammar(info.scopeName);
  })().catch(() => null);

  grammarCache.set(info.path, promise);
  return promise;
}

/** Drop cached grammars so an updated upload takes effect on next open. */
export function clearGrammarCache() {
  grammarCache.clear();
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
  if (!info) return null;
  const grammar = await loadGrammarFor(info);
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
