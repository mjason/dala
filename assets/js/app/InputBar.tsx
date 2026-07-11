import React, { useEffect, useMemo, useRef, useState } from "react";
import { agentCommands, buildCSRFHeaders, listFiles, savePastedFile, transcribe } from "../ash_rpc";
import { blobToBase64, loadSpeechPrefs, startRecording, type Recorder } from "./speech";
import { rankFiles } from "./fuzzy";
import { fileToBase64, pasteName } from "./pasteFiles";
import { shortPath } from "./util";
import { useI18n } from "./i18n";
import { Kbd, modShiftCombo } from "./shortcuts";
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
  onSend: (text: string, submit: boolean) => void;
  onClose: () => void;
  onError: (message: string) => void;
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
  onSend,
  onClose,
  onError,
}: Props) {
  const { t } = useI18n();
  const setValue = onChange;
  const [files, setFiles] = useState<string[] | null>(null);
  const [mention, setMention] = useState<{ start: number; query: string } | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const [slash, setSlash] = useState<string | null>(null);
  const [commands, setCommands] = useState<{ name: string; description: string }[] | null>(null);
  const [detectedApp, setDetectedApp] = useState<string | null>(null);
  const cursorRef = useRef(0);
  const attachRef = useRef<HTMLInputElement>(null);
  const [voice, setVoice] = useState<"idle" | "recording" | "busy">("idle");
  const recorderRef = useRef<Recorder | null>(null);

  // The app-level shortcut (mod+shift+M / client menu) pokes us here.
  const toggleVoiceRef = useRef<() => Promise<void>>(async () => {});
  useEffect(() => {
    const onVoice = () => void toggleVoiceRef.current();
    window.addEventListener("dala:voice", onVoice);
    return () => window.removeEventListener("dala:voice", onVoice);
  }, []);

  // Push-to-talk: click starts the mic, click again stops → transcribe →
  // the text lands at the end of the draft.
  const toggleVoice = async () => {
    if (voice === "busy") return;
    if (voice === "recording") {
      setVoice("busy");
      try {
        const wav = await recorderRef.current!.stop();
        recorderRef.current = null;
        const prefs = loadSpeechPrefs();
        const result = await transcribe({
          input: {
            endpoint: prefs.endpoint,
            model: prefs.model,
            apiKey: prefs.apiKey || undefined,
            audioBase64: await blobToBase64(wav),
          },
          fields: ["text", "error"] as never,
          headers: buildCSRFHeaders(),
        });
        const data = result.success
          ? (result.data as unknown as { text: string | null; error: string | null })
          : null;
        if (!data || data.error || !data.text) {
          onError(data?.error ?? t("speechFailed"));
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
    if (!loadSpeechPrefs().endpoint) {
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

  // File list loads lazily on the first `@`, once per composer open.
  useEffect(() => {
    if (!mention || files !== null) return;
    let stale = false;
    void listFiles({
      input: { path: root },
      fields: ["root", "files", "truncated"],
      headers: buildCSRFHeaders(),
    }).then((result) => {
      if (stale) return;
      if (result.success) {
        setFiles((result.data as unknown as { files: string[] }).files);
      } else {
        setFiles([]);
      }
    });
    return () => {
      stale = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mention !== null]);

  const matches = useMemo(
    () => (mention ? rankFiles(mention.query, files ?? [], 60) : []),
    [mention, files],
  );

  useEffect(() => {
    if (slash === null || commands !== null) return;
    let stale = false;
    void agentCommands({
      input: { id: sessionId },
      fields: ["app", "commands"] as never,
      headers: buildCSRFHeaders(),
    }).then((result) => {
      if (stale) return;
      if (result.success) {
        const data = result.data as unknown as {
          app: string;
          commands: { name: string; description: string }[];
        };
        setCommands(data.commands);
        setDetectedApp(data.app === "shell" || data.app === "unknown" ? null : data.app);
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
    // Agents understand the `@file` convention; a plain shell command wants
    // the bare path.
    const inserted = (app ?? detectedApp) && AGENT_LABELS[(app ?? detectedApp)!] ? `@${path}` : path;
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
        const result = await savePastedFile({
          input: { name: pasteName(file), contentBase64 },
          fields: ["path"],
          headers: buildCSRFHeaders(),
        });
        if (result.success) {
          const path = (result.data as unknown as { path: string }).path;
          setValue(value && !value.endsWith(" ") ? `${value} ${path} ` : `${value}${path} `);
        } else {
          onError(result.errors[0]?.message ?? t("uploadFailed"));
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

  return (
    <div id="input-bar" className="relative shrink-0 border-t border-line bg-bg1 px-3 pt-2 pb-1.5">
      {slash !== null && slashMatches.length > 0 && !mention && (
        <div
          id="slash-menu"
          className="absolute bottom-full left-3 z-10 mb-1 max-h-72 w-[34rem] max-w-[90%] overflow-y-auto rounded-lg border border-line bg-bg1 py-1 shadow-2xl shadow-black/50"
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
      {mention && matches.length > 0 && (
        <div
          id="mention-menu"
          className="absolute bottom-full left-3 z-10 mb-1 max-h-64 w-[32rem] max-w-[90%] overflow-y-auto rounded-lg border border-line bg-bg1 py-1 shadow-2xl shadow-black/50"
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
              {m.path}
            </button>
          ))}
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
      />

      <div className="mt-1 flex items-center gap-2">
        <button
          id="input-bar-send"
          onClick={send}
          disabled={!value.trim()}
          className="inline-flex shrink-0 items-center gap-1.5 rounded-md bg-mint px-2.5 py-1 text-[12px] font-medium text-black transition-all hover:brightness-110 active:scale-[0.98] disabled:opacity-40"
        >
          {t("inputBarSend")} <Kbd>⇧⏎</Kbd>
        </button>
        <button
          id="input-bar-mention"
          onClick={() => {
            const inject = value === "" || value.endsWith(" ") ? "@" : " @";
            setValue(value + inject);
          }}
          className="shrink-0 rounded-md border border-line px-2 py-1 font-mono text-[12px] text-fg-muted transition-colors hover:border-mint/60 hover:text-mint"
          title={t("composerMention")}
        >
          @
        </button>
        <button
          id="input-bar-attach"
          onClick={() => attachRef.current?.click()}
          className="grid h-6 w-6 shrink-0 place-items-center rounded-md border border-line text-fg-muted transition-colors hover:border-mint/60 hover:text-mint"
          title={t("composerAttach")}
        >
          <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
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
          id="input-bar-voice"
          onClick={() => void toggleVoice()}
          className={[
            "grid h-6 w-6 shrink-0 place-items-center rounded-md border transition-colors",
            voice === "recording"
              ? "animate-pulse border-red-400/70 text-red-400"
              : voice === "busy"
                ? "border-line text-fg-muted opacity-60"
                : "border-line text-fg-muted hover:border-mint/60 hover:text-mint",
          ].join(" ")}
          title={`${voice === "recording" ? t("speechStop") : t("speechStart")} · ${modShiftCombo("m")}`}
        >
          <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
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
          {t("composerHide")} <Kbd>{modShiftCombo("k")}</Kbd>
        </span>
      </div>
    </div>
  );
}
