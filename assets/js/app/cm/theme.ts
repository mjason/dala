import { EditorView } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import type { Extension } from "@codemirror/state";
import type { ResolvedTheme } from "../theme";
import { codeMirrorColors } from "../themePalette";

/**
 * Dala's CodeMirror theme: same palette the highlight.js theme used, mapped
 * onto lezer's highlighting tags, plus themed chrome for gutters, selection,
 * search panel and the merge view.
 */

export function dalaTheme(theme: ResolvedTheme): Extension {
  const colors = codeMirrorColors(theme);
  const dalaHighlightStyle = HighlightStyle.define([
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
    {
      tag: [t.typeName, t.className, t.standard(t.variableName), t.namespace],
      color: colors.type,
    },
    {
      tag: [t.meta, t.documentMeta, t.docComment, t.processingInstruction],
      color: colors.fgMuted,
    },
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
      scrollbarColor: `${colors.scrollbar} transparent`,
    },
    ".cm-content": { caretColor: colors.mint, padding: "10px 0" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: colors.mint },
    "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, ::selection":
      { backgroundColor: colors.selection },
    ".cm-selectionMatch": { backgroundColor: "rgba(77, 195, 138, 0.15)" },
    ".cm-gutters": {
      backgroundColor: colors.gutter,
      color: colors.gutterText,
      borderRight: `1px solid ${colors.line}`,
    },
    ".cm-lineNumbers .cm-gutterElement": { padding: "0 10px 0 14px" },
    ".cm-activeLine": { backgroundColor: colors.activeLine },
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
    ".cm-hunk-actions": {
      display: "flex",
      gap: "6px",
      padding: "3px 10px",
      backgroundColor: colors.hunk,
      borderTop: `1px solid ${colors.line}`,
      borderBottom: `1px solid ${colors.line}`,
    },
    ".cm-hunk-button": {
      border: `1px solid ${colors.line}`,
      borderRadius: "5px",
      padding: "1px 8px",
      fontSize: "10px",
      fontFamily: '"JetBrainsMono NFM", monospace',
      cursor: "pointer",
      backgroundColor: "transparent",
      color: colors.fgMuted,
    },
    ".cm-hunk-button:hover": { color: colors.fg, borderColor: colors.fgMuted },
    ".cm-hunk-button-primary": { color: colors.mint, borderColor: "rgba(76, 195, 138, 0.5)" },
    ".cm-hunk-button-primary:hover": {
      color: colors.mint,
      backgroundColor: "rgba(76, 195, 138, 0.1)",
      borderColor: colors.mint,
    },
    ".cm-hunk-button-danger:hover": {
      color: colors.danger,
      borderColor: "rgba(229, 113, 110, 0.6)",
      backgroundColor: "rgba(229, 113, 110, 0.08)",
    },
    ".cm-merge-revert": { width: "0", display: "none" },
    },
    { dark: theme === "dark" },
  );

  return [chrome, syntaxHighlighting(dalaHighlightStyle)];
}
