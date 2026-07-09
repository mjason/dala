import React, { useEffect, useRef, useState } from "react";
import { EditorState } from "@codemirror/state";
import { EditorView, lineNumbers } from "@codemirror/view";
import { MergeView, unifiedMergeView } from "@codemirror/merge";
import type { Extension } from "@codemirror/state";
import { dalaTheme } from "./cm/theme";
import { languageExtension } from "./cm/languages";

type Props = {
  oldText: string;
  newText: string;
  mode: "inline" | "split";
  wrap: boolean;
  filename: string;
};

/**
 * Syntax-highlighted diff for one file, driven by the full old/new contents
 * (VS Code style): character-level change marks, collapsed unchanged regions
 * and real line numbers, via @codemirror/merge.
 */
export default function CmDiff({ oldText, newText, mode, wrap, filename }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const [language, setLanguage] = useState<Extension | null | "loading">("loading");

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      const loaded = await languageExtension(filename);
      if (!cancelled) setLanguage(loaded);
    })();

    return () => {
      cancelled = true;
    };
  }, [filename]);

  useEffect(() => {
    const host = hostRef.current;
    if (!host || language === "loading") return;

    const shared: Extension[] = [
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      lineNumbers(),
      dalaTheme,
      ...(wrap ? [EditorView.lineWrapping] : []),
      ...(language ? [language] : []),
    ];
    const collapseUnchanged = { margin: 3, minSize: 4 };

    let destroy: () => void;

    if (mode === "split") {
      const view = new MergeView({
        parent: host,
        a: { doc: oldText, extensions: shared },
        b: { doc: newText, extensions: shared },
        gutter: true,
        highlightChanges: true,
        collapseUnchanged,
      });
      destroy = () => view.destroy();
    } else {
      const view = new EditorView({
        parent: host,
        state: EditorState.create({
          doc: newText,
          extensions: [
            ...shared,
            unifiedMergeView({
              original: oldText,
              mergeControls: false,
              gutter: true,
              collapseUnchanged,
            }),
          ],
        }),
      });
      destroy = () => view.destroy();
    }

    return destroy;
  }, [oldText, newText, mode, wrap, language]);

  return <div ref={hostRef} data-cm-diff className="min-h-0" />;
}
