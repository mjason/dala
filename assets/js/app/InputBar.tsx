import React, { useEffect, useMemo, useRef, useState } from "react";
import { agentCommands, listFiles, savePastedFile, speechSettings, transcribe } from "../ash_rpc";
import { call } from "./rpc";
import { blobToBase64, startRecording, type Recorder } from "./speech";
import { rankFiles } from "./fuzzy";
import { fileToBase64, pasteName } from "./pasteFiles";
import { shortPath } from "./util";
import { useI18n } from "./i18n";
import { isTopWindow, Kbd, modShiftCombo, popWindow, pushWindow } from "./shortcuts";
import { comboToCodeMirror, formatCombo, loadBindings, onBindingsChange } from "./keybindings";
import ComposerEditor from "./ComposerEditor";

type Props = {
  sessionId: string;
  /** Root for @-mention file search — the active session's cwd. */
  root: string;
  /** Foreground app in the session ("claude", "shell", …) for the placeholder. */
  app: string | null;
  /** Draft lives in the parent so agent-driven auto close/open keeps it. */
  value: string;
  onChange: (value: string) => void;
  /** Bumped on user-initiated opens; auto-opens must not steal focus. */
  focusNonce: number;
  focusConsumed: number;
  onFocusConsumed: (nonce: number) => void;
  onSend: (text: string, submit: boolean) => void;
  onClose: () => void;
  onError: (message: string) => void;
  /** The editor's height changed (bounded auto-grow) — refit the terminal. */
  onResize: () => void;
};

export const AGENT_LABELS: Record<string, string> = {
  claude: "Claude Code",
  opencode: "opencode",
  codex: "Codex",
  gemini: "Gemini",
  copilot: "Copilot",
};

/** The `/command` being typed at the START of the draft, if any. */
function slashAt(value: string, cursor: number): string | null {
  if (!value.startsWith("/")) return null;
  const token = value.slice(0, cursor);
  return /^\/[a-z-]*$/.test(token) ? token : null;
}

/** The `@token` currently being typed at the cursor, if any. */
function mentionAt(value: string, cursor: number): { start: number; query: string } | null {
  const before = value.slice(0, cursor);
  const match = /(^|\s)@([^\s@]*)$/.exec(before);
  if (!match) return null;
  return { start: cursor - match[2].length - 1, query: match[2] };
}

/**
 * Warp-style composer (their Ctrl-G rich input): compose locally — IME,
 * editing and cursor moves never round-trip the PTY — then deliver the
 * whole line at once. Works for plain shell commands and agent prompts;
 * `@` fuzzy-references files under the session's directory.
 */
export default function InputBar({
  sessionId,
  root,
  app,
  value,
  onChange,
  focusNonce,
  focusConsumed,
  onFocusConsumed,
  onSend,
  onClose,
  onError,
  onResize,
}: Props) {
  const { t } = useI18n();
  const setValue = onChange;
  const [files, setFiles] = useState<string[] | null>(null);
  const [filesTruncated, setFilesTruncated] = useState(false);
  const [mention, setMention] = useState<{ start: number; query: string } | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const [slash, setSlash] = useState<string | null>(null);
  const [commands, setCommands] = useState<{ name: string; description: string }[] | null>(null);
  const [detectedApp, setDetectedApp] = useState<string | null>(null);
  const cursorRef = useRef(0);
  const attachRef = useRef<HTMLInputElement>(null);
  const [bindings, setBindings] = useState(loadBindings);
  useEffect(() => onBindingsChange(setBindings), []);

  // Fullscreen: the bar leaves the flow and overlays the whole session area.
  // Per-mount on purpose — reopening the composer starts back in normal mode.
  const [fullscreen, setFullscreen] = useState(false);
  // While fullscreen a spacer holds the bar's old slot, so the terminal
  // behind the overlay keeps its grid (no SIGWINCH round-trip for its TUI).
  const [spacerHeight, setSpacerHeight] = useState(0);
  const barRef = useRef<HTMLDivElement>(null);
  const toggleFullscreen = () => {
    if (!fullscreen) setSpacerHeight(barRef.current?.offsetHeight ?? 0);
    setFullscreen((v) => !v);
  };

  // Fullscreen participates in the window stack: Escape must close the
  // topmost layer only — a preview above us first, then fullscreen, and only
  // then (next press, via the editor's keymap) the composer itself. Open
  // mention/slash menus close before fullscreen, matching the in-editor
  // keymap's order (state read via ref: the handler registers once per
  // fullscreen entry but must see current menus).
  const menusRef = useRef({ mention, slash });
  menusRef.current = { mention, slash };
  useEffect(() => {
    if (!fullscreen) return;
    const token = pushWindow();
    const handler = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented || !isTopWindow(token)) return;
      e.preventDefault();
      if (menusRef.current.mention) setMention(null);
      else if (menusRef.current.slash !== null) setSlash(null);
      else setFullscreen(false);
    };
    window.addEventListener("keydown", handler);
    return () => {
      window.removeEventListener("keydown", handler);
      popWindow(token);
    };
  }, [fullscreen]);

  const insertMention = () => {
    const inject = value === "" || value.endsWith(" ") ? "@" : " @";
    setValue(value + inject);
  };
  const insertMentionRef = useRef(insertMention);
  insertMentionRef.current = insertMention;

  // Keyboard shortcuts for the toolbar buttons arrive as app-level actions.
  useEffect(() => {
    const onAction = (e: Event) => {
      const id = (e as CustomEvent).detail;
      if (id === "composerMention") insertMentionRef.current();
      if (id === "composerAttach") attachRef.current?.click();
    };
    window.addEventListener("dala:action", onAction);
    return () => window.removeEventListener("dala:action", onAction);
  }, []);

  const [voice, setVoice] = useState<"idle" | "recording" | "busy">("idle");
  const recorderRef = useRef<Recorder | null>(null);

  // The app-level shortcut (mod+shift+M / client menu) pokes us here.
  const toggleVoiceRef = useRef<() => Promise<void>>(async () => {});
  useEffect(() => {
    const onVoice = () => void toggleVoiceRef.current();
    window.addEventListener("dala:voice", onVoice);
    return () => window.removeEventListener("dala:voice", onVoice);
  }, []);

  // The server's "nothing configured" sentinel becomes the localized nudge;
  // anything else is a real endpoint/network error and speaks for itself.
  const speechError = (error?: string | null) =>
    error === "speech_not_configured" ? t("speechNotConfigured") : (error ?? t("speechFailed"));

  // Push-to-talk: click starts the mic, click again stops → transcribe →
  // the text lands at the end of the draft.
  const toggleVoice = async () => {
    if (voice === "busy") return;
    if (voice === "recording") {
      setVoice("busy");
      try {
        const wav = await recorderRef.current!.stop();
        recorderRef.current = null;
        // Endpoint/model/key are the SERVER's business now: shared across
        // devices, and a client-named URL would be an SSRF pump.
        const result = await call<{ text: string | null; error: string | null }>(transcribe, {
          input: {
            cwd: root,
            audioBase64: await blobToBase64(wav),
          },
          fields: ["text", "error"] as never,
        });
        const data = result.ok ? result.data : null;
        if (!data || data.error || !data.text) {
          onError(speechError(data?.error));
        } else {
          setValue(value === "" || value.endsWith(" ") ? value + data.text : value + " " + data.text);
        }
      } catch (error) {
        onError(error instanceof Error ? error.message : t("speechFailed"));
      } finally {
        setVoice("idle");
      }
      return;
    }
    // Ask the server whether a speech endpoint is configured before opening
    // the mic — recording into a void is a lousy way to find out.
    const settings = await call<{ endpoint: string }>(speechSettings, {
      input: {},
      fields: ["endpoint"] as never,
    });
    if (!settings.ok || !settings.data.endpoint) {
      onError(t("speechNotConfigured"));
      return;
    }
    try {
      recorderRef.current = await startRecording();
      setVoice("recording");
    } catch (error) {
      const name = error instanceof DOMException ? error.name : "";
      onError(
        window.isSecureContext === false || !navigator.mediaDevices
          ? t("speechInsecureContext")
          : name === "NotAllowedError" || name === "SecurityError"
            ? t("speechMicSystemDenied")
            : name === "NotFoundError" || name === "OverconstrainedError"
              ? t("speechNoMic")
              : `${t("speechMicDenied")}${name ? ` (${name})` : ""}`,
      );
    }
  };
  toggleVoiceRef.current = toggleVoice;

  // A root change (session switch, cd) makes the cached list stale: drop it
  // so the effect below refetches on the next `@`.
  useEffect(() => {
    setFiles(null);
    setFilesTruncated(false);
  }, [root]);

  // File list loads lazily on the first `@`, once per composer open (and
  // again after a root change resets it above).
  useEffect(() => {
    if (!mention || files !== null) return;
    let stale = false;
    void call<{ files: string[]; truncated: boolean }>(listFiles, {
      input: { path: root },
      fields: ["root", "files", "truncated"],
    }).then((result) => {
      if (stale) return;
      if (result.ok) {
        setFiles(result.data.files);
        setFilesTruncated(result.data.truncated);
      } else {
        setFiles([]);
      }
    });
    return () => {
      stale = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mention !== null, files === null, root]);

  const matches = useMemo(
    () => (mention ? rankFiles(mention.query, files ?? [], 60, root) : []),
    [mention, files, root],
  );

  useEffect(() => {
    if (slash === null || commands !== null) return;
    let stale = false;
    void call<{
      app: string;
      commands: { name: string; description: string }[];
    }>(agentCommands, {
      input: { id: sessionId },
      fields: ["app", "commands"] as never,
    }).then((result) => {
      if (stale) return;
      if (result.ok) {
        setCommands(result.data.commands);
        setDetectedApp(
          result.data.app === "shell" || result.data.app === "unknown" ? null : result.data.app,
        );
      } else {
        setCommands([]);
      }
    });
    return () => {
      stale = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [slash !== null]);

  const slashMatches = useMemo(() => {
    if (slash === null) return [];
    return (commands ?? []).filter((c) => c.name.startsWith(slash));
  }, [slash, commands]);

  const pickMention = (path: string) => {
    if (!mention) return;
    // Whitespace must be backslash-escaped — both shells and claude code's
    // @-file parser stop at a bare space. Only whitespace: escaping anything
    // else would corrupt the path for claude's parser.
    const escaped = path.replace(/[ \t]/g, (ch) => `\\${ch}`);
    // Agents understand the `@file` convention; a plain shell command wants
    // the bare path.
    const inserted =
      (app ?? detectedApp) && AGENT_LABELS[(app ?? detectedApp)!] ? `@${escaped}` : escaped;
    const cursor = cursorRef.current || value.length;
    const next = `${value.slice(0, mention.start)}${inserted} ${value.slice(cursor)}`;
    setValue(next);
    setMention(null);
  };

  useEffect(() => {
    document
      .querySelector("#mention-menu [data-menu-selected], #slash-menu [data-menu-selected]")
      ?.scrollIntoView({ block: "nearest" });
  }, [mentionIndex]);

  const pickSlash = (command: { name: string }) => {
    setValue(command.name + " " + value.slice((slash ?? "").length).trimStart());
    setSlash(null);
  };

  const send = () => {
    if (!value.trim()) return;
    onSend(value, true);
    setValue("");
    setMention(null);
  };

  const attach = async (list: FileList | null) => {
    if (!list || list.length === 0) return;
    for (const file of Array.from(list)) {
      try {
        const contentBase64 = await fileToBase64(file);
        const result = await call<{ path: string }>(savePastedFile, {
          input: { name: pasteName(file), contentBase64 },
          fields: ["path"],
        });
        if (result.ok) {
          const path = result.data.path;
          setValue(value && !value.endsWith(" ") ? `${value} ${path} ` : `${value}${path} `);
        } else {
          onError(result.error || t("uploadFailed"));
        }
      } catch {
        onError(t("uploadFailed"));
      }
    }
  };

  const effectiveApp = app ?? detectedApp;
  const agentLabel = effectiveApp ? AGENT_LABELS[effectiveApp] : null;
  const placeholder = agentLabel
    ? t("composerAgentPlaceholder", { agent: agentLabel })
    : t("composerShellPlaceholder");

  // Fullscreen anchors the pickers just above the toolbar row instead of
  // above the (viewport-covering) bar, which would land them offscreen.
  const menuAnchor = fullscreen ? "bottom-16" : "bottom-full mb-1";

  return (
    <>
      {fullscreen && (
        <div id="input-bar-spacer" className="shrink-0" style={{ height: spacerHeight }} />
      )}
    <div
      ref={barRef}
      id="input-bar"
      data-fullscreen={fullscreen ? "true" : undefined}
      className={[
        "border-t border-line bg-bg1 px-3 pt-2 pb-1.5",
        fullscreen ? "absolute inset-0 z-20 flex flex-col" : "relative shrink-0",
      ].join(" ")}
    >
      {slash !== null && slashMatches.length > 0 && !mention && (
        <div
          id="slash-menu"
          className={`absolute ${menuAnchor} left-3 z-10 max-h-72 w-[34rem] max-w-[90%] overflow-y-auto rounded-lg border border-line bg-bg1 py-1 shadow-2xl shadow-black/50`}
        >
          {slashMatches.map((c, i) => (
            <button
              key={c.name}
              data-slash-item={c.name}
              data-menu-selected={i === mentionIndex || undefined}
              onMouseDown={(e) => {
                e.preventDefault();
                pickSlash(c);
              }}
              className={`flex w-full items-baseline gap-3 px-3 py-1 text-left ${
                i === mentionIndex ? "bg-bg2" : "hover:bg-bg2/50"
              }`}
            >
              <span
                className={`shrink-0 font-mono text-[13px] ${
                  i === mentionIndex ? "text-mint" : "text-fg"
                }`}
              >
                {c.name}
              </span>
              <span className="truncate text-[12px] text-fg-muted/70">{c.description}</span>
            </button>
          ))}
        </div>
      )}
      {mention && (matches.length > 0 || (filesTruncated && files !== null)) && (
        <div
          id="mention-menu"
          className={`absolute ${menuAnchor} left-3 z-10 max-h-64 w-[32rem] max-w-[90%] overflow-y-auto rounded-lg border border-line bg-bg1 py-1 shadow-2xl shadow-black/50`}
        >
          {matches.map((m, i) => (
            <button
              key={m.path}
              data-mention-item={m.path}
              data-menu-selected={i === mentionIndex || undefined}
              onMouseDown={(e) => {
                e.preventDefault();
                pickMention(m.path);
              }}
              className={`block w-full truncate px-3 py-1 text-left font-mono text-[13px] ${
                i === mentionIndex ? "bg-bg2 text-mint" : "text-fg-muted hover:text-fg"
              }`}
            >
              {/* Show the NFC form; the pick inserts the original bytes. */}
              {m.display}
            </button>
          ))}
          {filesTruncated && (
            <div
              id="mention-truncated"
              className={`px-3 py-1 text-[11px] text-fg-muted/60 ${
                matches.length > 0 ? "border-t border-line/60" : ""
              }`}
            >
              {t("mentionTruncated")}
            </div>
          )}
        </div>
      )}

      <ComposerEditor
        value={value}
        onChange={(next) => {
          setValue(next);
        }}
        placeholder={placeholder}
        focusNonce={focusNonce}
        onEnter={send}
        onEscape={() => {
          if (mention) setMention(null);
          else if (slash !== null) setSlash(null);
          else if (fullscreen) setFullscreen(false);
          else onClose();
        }}
        onArrow={(dir) => {
          if (mention && matches.length > 0) {
            setMentionIndex((i) => Math.max(0, Math.min(i + dir, matches.length - 1)));
            return true;
          }
          if (slashMatches.length > 0) {
            setMentionIndex((i) => Math.max(0, Math.min(i + dir, slashMatches.length - 1)));
            return true;
          }
          return false;
        }}
        onPick={() => {
          if (mention && matches.length > 0) {
            pickMention(matches[mentionIndex].path);
            return true;
          }
          if (slashMatches.length > 0) {
            pickSlash(slashMatches[Math.min(mentionIndex, slashMatches.length - 1)]);
            return true;
          }
          return false;
        }}
        onCursor={(text, pos) => {
          cursorRef.current = pos;
          setMention(mentionAt(text, pos));
          setSlash(slashAt(text, pos));
          setMentionIndex(0);
        }}
        onFiles={(files) => {
          const list = new DataTransfer();
          for (const f of files) list.items.add(f);
          void attach(list.files);
        }}
        sendKey={comboToCodeMirror(bindings.composerSend)}
        focusConsumed={focusConsumed}
        onFocusConsumed={onFocusConsumed}
        fullscreen={fullscreen}
        onResize={onResize}
      />

      <div className="mt-1 flex items-center gap-2">
        <button
          id="input-bar-send"
          onClick={send}
          disabled={!value.trim()}
          className="inline-flex shrink-0 items-center gap-1.5 rounded-md bg-mint px-2.5 py-1 text-[12px] font-medium text-black transition-all hover:brightness-110 active:scale-[0.98] disabled:opacity-40 pointer-coarse:min-h-10 pointer-coarse:px-4 pointer-coarse:text-sm"
        >
          {t("inputBarSend")}{" "}
          {/* A shortcut badge means nothing on touch (same policy as the
              composer strip's hint) — hide it on coarse pointers. */}
          <span className="contents pointer-coarse:hidden">
            <Kbd>{formatCombo(bindings.composerSend)}</Kbd>
          </span>
        </button>
        <button
          id="input-bar-mention"
          onClick={insertMention}
          className="shrink-0 rounded-md border border-line px-2 py-1 font-mono text-[12px] text-fg-muted transition-colors hover:border-mint/60 hover:text-mint pointer-coarse:min-h-10 pointer-coarse:min-w-10 pointer-coarse:text-sm"
          title={`${t("composerMention")} · ${formatCombo(bindings.composerMention)}`}
        >
          @
        </button>
        <button
          id="input-bar-attach"
          onClick={() => attachRef.current?.click()}
          className="grid h-6 w-6 shrink-0 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:border-mint/60 hover:text-mint pointer-coarse:h-10 pointer-coarse:w-10"
          title={`${t("composerAttach")} · ${formatCombo(bindings.composerAttach)}`}
        >
          <svg viewBox="0 0 16 16" className="h-3 w-3 pointer-coarse:h-4 pointer-coarse:w-4" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M8 3v10M3 8h10" strokeLinecap="round" />
          </svg>
        </button>
        <input
          ref={attachRef}
          type="file"
          multiple
          className="hidden"
          onChange={(e) => {
            void attach(e.target.files);
            e.target.value = "";
          }}
        />
        <button
          id="composer-fullscreen"
          aria-label={fullscreen ? t("composerFullscreenExit") : t("composerFullscreen")}
          title={fullscreen ? `${t("composerFullscreenExit")} · Esc` : t("composerFullscreen")}
          // Keep the editor focused through the toggle (Esc must keep
          // working right after the click).
          onMouseDown={(e) => e.preventDefault()}
          onClick={toggleFullscreen}
          className={`grid h-6 w-6 shrink-0 place-items-center rounded-md border transition-colors pointer-coarse:h-10 pointer-coarse:w-10 ${
            fullscreen
              ? "border-mint/50 text-mint"
              : "border-line text-fg-muted hover:border-mint/60 hover:text-mint"
          }`}
        >
          {fullscreen ? (
            <svg viewBox="0 0 16 16" className="h-3 w-3 pointer-coarse:h-4 pointer-coarse:w-4" fill="none" stroke="currentColor" strokeWidth="1.5">
              <path d="M6 2.5V6H2.5M10 2.5V6h3.5M6 13.5V10H2.5M10 13.5V10h3.5" strokeLinecap="round" />
            </svg>
          ) : (
            <svg viewBox="0 0 16 16" className="h-3 w-3 pointer-coarse:h-4 pointer-coarse:w-4" fill="none" stroke="currentColor" strokeWidth="1.5">
              <path d="M6 2.5H2.5V6M10 2.5h3.5V6M6 13.5H2.5V10M10 13.5h3.5V10" strokeLinecap="round" />
            </svg>
          )}
        </button>
        <button
          id="input-bar-voice"
          data-voice={voice}
          onClick={() => void toggleVoice()}
          className={[
            "grid h-6 w-6 shrink-0 place-items-center rounded-md border transition-colors pointer-coarse:h-10 pointer-coarse:w-10",
            voice === "recording"
              ? "animate-pulse border-red-400/70 text-red-400"
              : voice === "busy"
                ? "border-line text-fg-muted opacity-60"
                : "border-line text-fg-muted hover:border-mint/60 hover:text-mint",
          ].join(" ")}
          title={`${voice === "recording" ? t("speechStop") : t("speechStart")} · ${formatCombo(bindings.voice)}`}
        >
          <svg viewBox="0 0 16 16" className="h-3 w-3 pointer-coarse:h-4 pointer-coarse:w-4" fill="none" stroke="currentColor" strokeWidth="1.5">
            <rect x="6" y="2" width="4" height="7" rx="2" />
            <path d="M3.5 8a4.5 4.5 0 0 0 9 0M8 12.5V14" strokeLinecap="round" />
          </svg>
        </button>
        {agentLabel && (
          <span className="rounded-full bg-mint/10 px-2 py-0.5 font-mono text-[11px] text-mint">
            {agentLabel}
          </span>
        )}
        <div className="flex-1" />
        <span className="hidden truncate font-mono text-[11px] text-fg-muted/60 sm:block" title={root}>
          {shortPath(root, 40)}
        </span>
        <span className="hidden shrink-0 items-center gap-1 font-mono text-[11px] text-fg-muted/60 sm:inline-flex">
          {t("kbFocusTerminal")} <Kbd>{formatCombo(bindings.focusTerminal)}</Kbd>
        </span>
        <span className="hidden shrink-0 items-center gap-1 font-mono text-[11px] text-fg-muted/60 sm:inline-flex">
          {t("composerHide")} <Kbd>{formatCombo(bindings.composer)}</Kbd>
        </span>
      </div>
    </div>
    </>
  );
}
