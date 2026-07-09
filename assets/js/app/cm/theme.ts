import { EditorView } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import type { Extension } from "@codemirror/state";

/**
 * Dala's CodeMirror theme: same palette the highlight.js theme used, mapped
 * onto lezer's highlighting tags, plus dark chrome for gutters, selection,
 * search panel and the merge view.
 */

const colors = {
  bg0: "#0b0c0e",
  bg1: "#121417",
  bg2: "#1b1e23",
  line: "#24272c",
  fg: "#e6e8eb",
  fgMuted: "#8f96a0",
  mint: "#4cc38a",
  comment: "#6b7280",
  keyword: "#b087c9",
  string: "#5fbf87",
  number: "#d9a860",
  title: "#6d9fd6",
  type: "#5fb8b8",
  danger: "#e5716e",
  selection: "#2d3f4d",
};

export const dalaHighlightStyle = HighlightStyle.define([
  { tag: [t.comment, t.quote], color: colors.comment, fontStyle: "italic" },
  { tag: [t.keyword, t.moduleKeyword, t.operatorKeyword, t.tagName], color: colors.keyword },
  { tag: [t.string, t.special(t.string), t.regexp, t.inserted], color: colors.string },
  { tag: [t.number, t.bool, t.null, t.atom, t.literal], color: colors.number },
  {
    tag: [
      t.function(t.variableName),
      t.function(t.propertyName),
      t.definition(t.variableName),
      t.attributeName,
      t.propertyName,
      t.macroName,
    ],
    color: colors.title,
  },
  { tag: [t.typeName, t.className, t.standard(t.variableName), t.namespace], color: colors.type },
  { tag: [t.meta, t.documentMeta, t.docComment, t.processingInstruction], color: colors.fgMuted },
  { tag: t.deleted, color: colors.danger },
  { tag: t.invalid, color: colors.danger },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strong, fontWeight: "600" },
  { tag: t.heading, color: colors.title, fontWeight: "600" },
  { tag: t.link, color: colors.title, textDecoration: "underline" },
  { tag: [t.url, t.escape], color: colors.type },
]);

const chrome = EditorView.theme(
  {
    "&": {
      backgroundColor: "transparent",
      color: colors.fg,
      fontSize: "13px",
    },
    "&.cm-editor": { height: "100%" },
    "&.cm-focused": { outline: "none" },
    ".cm-scroller": {
      fontFamily: '"JetBrainsMono NFM", monospace',
      lineHeight: "1.55",
      scrollbarWidth: "thin",
      scrollbarColor: "#2c3037 transparent",
    },
    ".cm-content": { caretColor: colors.mint, padding: "10px 0" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: colors.mint },
    "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, ::selection":
      { backgroundColor: colors.selection },
    ".cm-selectionMatch": { backgroundColor: "rgba(77, 195, 138, 0.15)" },
    ".cm-gutters": {
      backgroundColor: "rgba(18, 20, 23, 0.5)",
      color: "rgba(143, 150, 160, 0.45)",
      borderRight: `1px solid ${colors.line}`,
    },
    ".cm-lineNumbers .cm-gutterElement": { padding: "0 10px 0 14px" },
    ".cm-activeLine": { backgroundColor: "rgba(27, 30, 35, 0.55)" },
    ".cm-activeLineGutter": { backgroundColor: "transparent", color: colors.fgMuted },
    ".cm-matchingBracket, &.cm-focused .cm-matchingBracket": {
      backgroundColor: "rgba(77, 195, 138, 0.2)",
      outline: "none",
    },
    ".cm-searchMatch": { backgroundColor: "rgba(217, 168, 96, 0.25)" },
    ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: "rgba(217, 168, 96, 0.5)" },

    // Search / goto panels.
    ".cm-panels": { backgroundColor: colors.bg1, color: colors.fg },
    ".cm-panels.cm-panels-bottom": { borderTop: `1px solid ${colors.line}` },
    ".cm-panel.cm-search": { padding: "6px 10px", fontFamily: '"JetBrainsMono NFM", monospace' },
    ".cm-panel.cm-search label": { fontSize: "11px", color: colors.fgMuted },
    ".cm-textfield": {
      backgroundColor: colors.bg0,
      border: `1px solid ${colors.line}`,
      borderRadius: "6px",
      color: colors.fg,
      fontSize: "12px",
    },
    ".cm-textfield:focus": { borderColor: "rgba(77, 195, 138, 0.6)", outline: "none" },
    ".cm-button": {
      backgroundColor: colors.bg2,
      backgroundImage: "none",
      border: `1px solid ${colors.line}`,
      borderRadius: "6px",
      color: colors.fg,
      fontSize: "12px",
      cursor: "pointer",
    },
    ".cm-button:active": { backgroundImage: "none", backgroundColor: colors.line },
    ".cm-panel.cm-search [name=close]": { color: colors.fgMuted, fontSize: "18px" },

    // Merge view (diff) colors.
    ".cm-changedLine, .cm-insertedLine": { backgroundColor: "rgba(95, 191, 135, 0.10)" },
    ".cm-deletedChunk": { backgroundColor: "rgba(229, 113, 110, 0.10)" },
    ".cm-changedText, .cm-insertedLine .cm-changedText": {
      background: "rgba(95, 191, 135, 0.28)",
      borderRadius: "2px",
    },
    ".cm-deletedText, .cm-deletedChunk .cm-deletedText": {
      background: "rgba(229, 113, 110, 0.3)",
      borderRadius: "2px",
    },
    ".cm-collapsedLines": {
      backgroundColor: colors.bg2,
      backgroundImage: "none",
      color: colors.fgMuted,
      fontSize: "11px",
      padding: "3px 12px",
      borderTop: `1px solid ${colors.line}`,
      borderBottom: `1px solid ${colors.line}`,
    },
    ".cm-collapsedLines:hover": { backgroundColor: colors.line },
    ".cm-mergeSpacer": { backgroundColor: "transparent" },
    ".cm-merge-revert": { width: "0", display: "none" },
  },
  { dark: true },
);

export const dalaTheme: Extension = [chrome, syntaxHighlighting(dalaHighlightStyle)];
