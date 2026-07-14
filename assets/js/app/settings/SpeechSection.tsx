import React, { useEffect, useState } from "react";
import {
  setSpeechPrompt,
  setSpeechSettings,
  speechPromptConfig,
  speechSettings,
} from "../../ash_rpc";
import { call } from "../rpc";
import { FieldLabel, Select, TextArea, TextInput } from "../ui";
import { useI18n } from "../i18n";
import {
  listMicrophones,
  loadSpeechPrefs,
  saveSpeechPrefs,
  type SpeechPrefs,
} from "../speech";

type ServerSettings = { endpoint: string; model: string; apiKeySet: boolean };

const EMPTY: ServerSettings = { endpoint: "", model: "", apiKeySet: false };
const SETTINGS_FIELDS = ["endpoint", "model", "apiKeySet"] as const;

// The RPC encoder sends a `false` map field as null — normalize once, here,
// so the rest of the component can trust the shape.
const normalize = (raw: Partial<ServerSettings> | null): ServerSettings => ({
  endpoint: raw?.endpoint ?? "",
  model: raw?.model ?? "",
  apiKeySet: raw?.apiKeySet === true,
});

/**
 * Voice input. The endpoint/model/API key live on the SERVER (shared by
 * every device you sign in from; the key never comes back down — only a
 * "configured" flag). Only the microphone is a browser-local choice.
 */
export default function SpeechSection({ root }: { root: string }) {
  const { t } = useI18n();
  const [prefs, setPrefs] = useState<SpeechPrefs>(loadSpeechPrefs);
  const [mics, setMics] = useState<{ deviceId: string; label: string }[]>([]);
  const [server, setServer] = useState<ServerSettings>(EMPTY);
  // "" while untouched: an empty box means "leave the stored key alone".
  const [apiKey, setApiKey] = useState("");
  const [settingsState, setSettingsState] = useState<
    "idle" | "dirty" | "saved" | "error"
  >("idle");
  // The transcription prompt is per-project: it lives in the dala.jsonc
  // nearest to the session's cwd (created there when missing), not in the
  // settings row.
  const [prompt, setPrompt] = useState("");
  const [promptPath, setPromptPath] = useState("");
  const [promptState, setPromptState] = useState<
    "idle" | "dirty" | "saved" | "error"
  >("idle");

  useEffect(() => {
    void listMicrophones().then(setMics);
  }, []);

  // Load the server settings. The one-time hand-off of legacy localStorage
  // prefs runs at app mount (see App.tsx), so by the time this panel opens the
  // server already holds anything that was migrated.
  useEffect(() => {
    let stale = false;
    void call<ServerSettings>(speechSettings, {
      input: {},
      fields: [...SETTINGS_FIELDS] as never,
    }).then((result) => {
      if (stale || !result.ok) return;
      setServer(normalize(result.data));
    });
    return () => {
      stale = true;
    };
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

  const pushSettings = async (input: {
    endpoint?: string;
    model?: string;
    apiKey?: string;
    clearApiKey?: boolean;
  }): Promise<ServerSettings | null> => {
    const result = await call<ServerSettings>(setSpeechSettings, {
      input,
      fields: [...SETTINGS_FIELDS] as never,
    });
    return result.ok ? normalize(result.data) : null;
  };

  // Endpoint/model persist on blur (like the prompt): typing every keystroke
  // to the server would hammer it for no benefit.
  const saveSettings = async (patch: Partial<ServerSettings> = {}) => {
    const next = { ...server, ...patch };
    setServer(next);
    const saved = await pushSettings({
      endpoint: next.endpoint,
      model: next.model,
    });
    if (saved) {
      setServer(saved);
      setSettingsState("saved");
    } else {
      setSettingsState("error");
    }
  };

  const saveApiKey = async () => {
    if (!apiKey) return;
    const saved = await pushSettings({ apiKey });
    setApiKey("");
    if (saved) {
      setServer(saved);
      setSettingsState("saved");
    } else {
      setSettingsState("error");
    }
  };

  const clearApiKey = async () => {
    setApiKey("");
    const saved = await pushSettings({ clearApiKey: true });
    if (saved) {
      setServer(saved);
      setSettingsState("saved");
    } else {
      setSettingsState("error");
    }
  };

  const savePrompt = async () => {
    if (promptState !== "dirty") return;
    const result = await call<{ path: string | null; error: string | null }>(
      setSpeechPrompt,
      {
        input: { dir: root, prompt },
        fields: ["path", "error"],
      },
    );
    const data = result.ok ? result.data : null;
    if (data && !data.error) {
      if (data.path) setPromptPath(data.path);
      setPromptState("saved");
    } else {
      setPromptState("error");
    }
  };

  const apply = (patch: Partial<SpeechPrefs>) =>
    setPrefs(saveSpeechPrefs(patch));

  return (
    <div className="space-y-4">
      <div>
        <div className="text-[13px] font-medium text-fg">
          {t("speechSection")}
        </div>
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">
          {t("speechSectionDesc")}
        </p>
      </div>
      <div>
        <FieldLabel>{t("speechEndpoint")}</FieldLabel>
        <TextInput
          id="speech-endpoint-input"
          value={server.endpoint}
          onChange={(e) => {
            setServer({ ...server, endpoint: e.target.value.trim() });
            setSettingsState("dirty");
          }}
          onBlur={() => void saveSettings()}
          placeholder="http://127.0.0.1:8000/v1"
        />
        <p className="mt-1 flex items-center gap-1.5 text-[12px] leading-relaxed text-fg-muted">
          <span id="speech-settings-status" className="font-mono text-[11px]">
            {settingsState === "saved"
              ? "✓"
              : settingsState === "error"
                ? "✗"
                : ""}
          </span>
          <span>{t("speechServerShared")}</span>
        </p>
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
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">
          {t("speechMicHint")}
        </p>
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
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">
          {t("speechPromptHint")}
        </p>
        {prompt.length > 300 && (
          <p
            id="speech-prompt-overflow"
            className="mt-1 text-[12px] text-amber-500"
          >
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
            value={server.model}
            onChange={(e) => {
              setServer({ ...server, model: e.target.value.trim() });
              setSettingsState("dirty");
            }}
            onBlur={() => void saveSettings()}
            placeholder="whisper-large-v3"
          />
        </div>
        <div>
          <FieldLabel>{t("speechApiKey")}</FieldLabel>
          <div className="flex items-center gap-2">
            <TextInput
              id="speech-api-key-input"
              type="password"
              value={apiKey}
              onChange={(e) => {
                setApiKey(e.target.value.trim());
                setSettingsState("dirty");
              }}
              onBlur={() => void saveApiKey()}
              placeholder={
                server.apiKeySet ? t("speechApiKeySet") : t("optional")
              }
            />
            {server.apiKeySet && (
              <button
                id="speech-api-key-clear"
                type="button"
                onClick={() => void clearApiKey()}
                className="shrink-0 rounded-md border border-border px-2 py-1 text-[12px] text-fg-muted transition-colors hover:bg-bg-hover hover:text-fg"
              >
                {t("speechApiKeyClear")}
              </button>
            )}
          </div>
          <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">
            {t("speechApiKeyHint")}
          </p>
        </div>
      </div>
    </div>
  );
}
