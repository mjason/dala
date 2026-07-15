import { EditorView } from "@codemirror/view";
import { openSearchPanel } from "@codemirror/search";
import { isMac } from "../shortcuts";

/**
 * Ctrl/Cmd+F opens the CodeMirror search panel even when the editor is NOT
 * focused — a file preview the user is only reading — instead of the browser's
 * native find, which is useless over CodeMirror's virtualized viewport. Events
 * a focused editor's own searchKeymap already handled arrive `defaultPrevented`
 * and are skipped, so this only kicks in for the unfocused case. Returns a
 * disposer to remove the listener.
 */
export function findOnModF(view: EditorView): () => void {
  const onKey = (e: KeyboardEvent) => {
    const mod = isMac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
    if (e.defaultPrevented || !mod || e.shiftKey || e.altKey) return;
    if (e.key !== "f" && e.key !== "F") return;
    e.preventDefault();
    view.focus();
    openSearchPanel(view);
  };
  window.addEventListener("keydown", onKey);
  return () => window.removeEventListener("keydown", onKey);
}
