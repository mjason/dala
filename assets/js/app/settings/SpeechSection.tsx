import React, { useEffect, useState } from "react";
import { setSpeechPrompt, speechPromptConfig } from "../../ash_rpc";
import { call } from "../rpc";
import { FieldLabel, Select, TextArea, TextInput } from "../ui";
import { useI18n } from "../i18n";
import { listMicrophones, loadSpeechPrefs, saveSpeechPrefs, type SpeechPrefs } from "../speech";

/**
 * Voice input: an OpenAI-compatible transcription endpoint (vLLM Whisper
 * serving etc.). Browser-local like the appearance prefs — changes persist
 * as you type, no save step.
 */
export default function SpeechSection({ root }: { root: string }) {
  const { t } = useI18n();
  const [prefs, setPrefs] = useState<SpeechPrefs>(loadSpeechPrefs);
  const [mics, setMics] = useState<{ deviceId: string; label: string }[]>([]);
  // The transcription prompt is per-project: it lives in the dala.jsonc
  // nearest to the session's cwd (created there when missing), not in
  // browser storage.
  const [prompt, setPrompt] = useState("");
  const [promptPath, setPromptPath] = useState("");
  const [promptState, setPromptState] = useState<"idle" | "dirty" | "saved" | "error">(
    "idle",
  );

  useEffect(() => {
    void listMicrophones().then(setMics);
  }, []);

  useEffect(() => {
    let stale = false;
    void call<{ path: string; prompt: string | null }>(speechPromptConfig, {
      input: { dir: root },
      fields: ["path", "exists", "prompt"],
    }).then((result) => {
      if (stale || !result.ok) return;
      setPrompt(result.data.prompt ?? "");
      setPromptPath(result.data.path);
    });
    return () => {
      stale = true;
    };
  }, [root]);

  const savePrompt = async () => {
    if (promptState !== "dirty") return;
    const result = await call<{ path: string | null; error: string | null }>(setSpeechPrompt, {
      input: { dir: root, prompt },
      fields: ["path", "error"],
    });
    const data = result.ok ? result.data : null;
    if (data && !data.error) {
      if (data.path) setPromptPath(data.path);
      setPromptState("saved");
    } else {
      setPromptState("error");
    }
  };

  const apply = (patch: Partial<SpeechPrefs>) => setPrefs(saveSpeechPrefs(patch));

  return (
    <div className="space-y-4">
      <div>
        <div className="text-[13px] font-medium text-fg">{t("speechSection")}</div>
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">{t("speechSectionDesc")}</p>
      </div>
      <div>
        <FieldLabel>{t("speechEndpoint")}</FieldLabel>
        <TextInput
          id="speech-endpoint-input"
          value={prefs.endpoint}
          onChange={(e) => apply({ endpoint: e.target.value.trim() })}
          placeholder="http://127.0.0.1:8000/v1"
        />
      </div>
      <div>
        <FieldLabel>{t("speechMic")}</FieldLabel>
        <Select
          id="speech-mic-select"
          value={prefs.micDeviceId}
          onChange={(e) => apply({ micDeviceId: e.target.value })}
        >
          <option value="">{t("speechMicAuto")}</option>
          {mics.map((mic) => (
            <option key={mic.deviceId} value={mic.deviceId}>
              {mic.label}
            </option>
          ))}
        </Select>
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">{t("speechMicHint")}</p>
      </div>
      <div>
        <FieldLabel>{t("speechPrompt")}</FieldLabel>
        <TextArea
          id="speech-prompt-input"
          value={prompt}
          onChange={(e) => {
            setPrompt(e.target.value);
            setPromptState("dirty");
          }}
          onBlur={() => void savePrompt()}
          placeholder={t("speechPromptPlaceholder")}
          rows={3}
        />
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">{t("speechPromptHint")}</p>
        {prompt.length > 300 && (
          <p id="speech-prompt-overflow" className="mt-1 text-[12px] text-amber-500">
            {t("speechPromptTail")}
          </p>
        )}
        <p className="mt-1 flex items-center gap-1.5 font-mono text-[11px] text-fg-muted/70">
          <span id="speech-prompt-status">
            {promptState === "saved" ? "✓" : promptState === "error" ? "✗" : ""}
          </span>
          {prompt.length > 0 && <span>{prompt.length}</span>}
          <span className="truncate" title={promptPath}>
            {promptPath}
          </span>
        </p>
      </div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <FieldLabel>{t("speechModel")}</FieldLabel>
          <TextInput
            id="speech-model-input"
            value={prefs.model}
            onChange={(e) => apply({ model: e.target.value.trim() })}
            placeholder="whisper-large-v3"
          />
        </div>
        <div>
          <FieldLabel>{t("speechApiKey")}</FieldLabel>
          <TextInput
            id="speech-api-key-input"
            type="password"
            value={prefs.apiKey}
            onChange={(e) => apply({ apiKey: e.target.value.trim() })}
            placeholder={t("optional")}
          />
        </div>
      </div>
    </div>
  );
}
