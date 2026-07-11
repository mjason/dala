import React, { useEffect, useRef, useState } from "react";
import { useI18n } from "./i18n";
import { Kbd } from "./shortcuts";

type Props = {
  onSend: (text: string, submit: boolean) => void;
  onClose: () => void;
};

/**
 * Warp-style native input bar: compose locally (IME, editing, cursor — all
 * zero-latency, no PTY round-trips, no TUI redraw per keystroke), then hand
 * the whole line to the terminal at once via bracketed paste + Enter. Built
 * for long CJK prompts into Claude Code / opencode; slash commands are still
 * best typed in the terminal directly (their completion menu needs
 * per-keystroke input).
 */
export default function InputBar({ onSend, onClose }: Props) {
  const { t } = useI18n();
  const [value, setValue] = useState("");
  const ref = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    ref.current?.focus();
  }, []);

  const send = () => {
    if (!value.trim()) return;
    onSend(value, true);
    setValue("");
  };

  return (
    <div id="input-bar" className="shrink-0 border-t border-line bg-bg1 px-3 py-2">
      <div className="flex items-end gap-2">
        <textarea
          ref={ref}
          id="input-bar-textarea"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            // Enter must not fire while the IME is still composing.
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              send();
              return;
            }
            if (e.key === "Escape") {
              e.preventDefault();
              onClose();
            }
          }}
          placeholder={t("inputBarPlaceholder")}
          rows={Math.min(6, Math.max(1, value.split("\n").length))}
          spellCheck={false}
          className="max-h-40 min-w-0 flex-1 resize-none rounded-md border border-line bg-bg0 px-3 py-1.5 font-mono text-[14px] leading-6 text-fg outline-none transition-colors placeholder:text-fg-muted/50 focus:border-mint/60"
        />
        <button
          id="input-bar-send"
          onClick={send}
          disabled={!value.trim()}
          className="inline-flex shrink-0 items-center gap-1.5 rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-black transition-all hover:brightness-110 active:scale-[0.98] disabled:opacity-40"
        >
          {t("inputBarSend")} <Kbd>⏎</Kbd>
        </button>
      </div>
    </div>
  );
}
