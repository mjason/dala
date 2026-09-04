import React, { useEffect, useRef, useState } from "react";
import {
  promptOptimizerSettings,
  setPromptOptimizerSettings,
} from "../../ash_rpc";
import { call } from "../rpc";
import { FieldLabel, TextArea, TextInput } from "../ui";
import { useI18n } from "../i18n";

type ServerSettings = {
  endpoint: string;
  model: string;
  prompt: string;
  apiKeySet: boolean;
};

const EMPTY: ServerSettings = {
  endpoint: "https://api.deepseek.com",
  model: "deepseek-v4-flash",
  prompt: "",
  apiKeySet: false,
};
const SETTINGS_FIELDS = ["endpoint", "model", "prompt", "apiKeySet"] as const;

const normalize = (raw: Partial<ServerSettings> | null): ServerSettings => ({
  endpoint: raw?.endpoint ?? EMPTY.endpoint,
  model: raw?.model ?? EMPTY.model,
  prompt: raw?.prompt ?? "",
  apiKeySet: raw?.apiKeySet === true,
});

export default function PromptOptimizerSection() {
  const { t } = useI18n();
  const [server, setServer] = useState<ServerSettings>(EMPTY);
  const [apiKey, setApiKey] = useState("");
  const [state, setState] = useState<"idle" | "dirty" | "saved" | "error">("idle");
  const revisionRef = useRef(0);

  useEffect(() => {
    let stale = false;
    void call<ServerSettings>(promptOptimizerSettings, {
      input: {},
      fields: [...SETTINGS_FIELDS] as never,
    }).then((result) => {
      if (!stale && result.ok && revisionRef.current === 0) setServer(normalize(result.data));
    });
    return () => {
      stale = true;
    };
  }, []);

  const push = async (input: {
    endpoint?: string;
    model?: string;
    prompt?: string;
    apiKey?: string;
    clearApiKey?: boolean;
  }): Promise<ServerSettings | null> => {
    const result = await call<ServerSettings>(setPromptOptimizerSettings, {
      input,
      fields: [...SETTINGS_FIELDS] as never,
    });
    return result.ok ? normalize(result.data) : null;
  };

  const saveSettings = async (patch: Partial<ServerSettings>) => {
    const revision = revisionRef.current;
    const saved = await push(patch);
    if (saved) {
      if (revisionRef.current === revision) {
        setServer(saved);
        setState("saved");
      }
    } else {
      setState("error");
    }
  };

  const saveApiKey = async () => {
    if (!apiKey) return;
    const revision = revisionRef.current;
    const saved = await push({ apiKey });
    setApiKey("");
    if (saved) {
      if (revisionRef.current === revision) {
        setServer(saved);
        setState("saved");
      }
    } else {
      setState("error");
    }
  };

  const clearApiKey = async () => {
    revisionRef.current += 1;
    const revision = revisionRef.current;
    setApiKey("");
    const saved = await push({ clearApiKey: true });
    if (saved) {
      if (revisionRef.current === revision) {
        setServer(saved);
        setState("saved");
      }
    } else {
      setState("error");
    }
  };

  const update = (patch: Partial<ServerSettings>) => {
    revisionRef.current += 1;
    setServer({ ...server, ...patch });
    setState("dirty");
  };

  return (
    <div className="space-y-4">
      <div>
        <div className="text-[13px] font-medium text-fg">{t("promptOptimizerSection")}</div>
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">
          {t("promptOptimizerSectionDesc")}
        </p>
      </div>

      <div>
        <FieldLabel>{t("promptOptimizerEndpoint")}</FieldLabel>
        <TextInput
          id="prompt-optimizer-endpoint-input"
          value={server.endpoint}
          onInput={(e) => update({ endpoint: e.currentTarget.value.trim() })}
          onBlur={() => void saveSettings({ endpoint: server.endpoint })}
          placeholder="https://api.deepseek.com"
        />
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <FieldLabel>{t("promptOptimizerModel")}</FieldLabel>
          <TextInput
            id="prompt-optimizer-model-input"
            value={server.model}
            onInput={(e) => update({ model: e.currentTarget.value.trim() })}
            onBlur={() => void saveSettings({ model: server.model })}
            placeholder="deepseek-v4-flash"
          />
        </div>
        <div>
          <FieldLabel>{t("promptOptimizerApiKey")}</FieldLabel>
          <div className="flex items-center gap-2">
            <TextInput
              id="prompt-optimizer-api-key-input"
              type="password"
              value={apiKey}
              onInput={(e) => {
                revisionRef.current += 1;
                setApiKey(e.currentTarget.value.trim());
                setState("dirty");
              }}
              onBlur={() => void saveApiKey()}
              placeholder={server.apiKeySet ? t("speechApiKeySet") : t("optional")}
            />
            {server.apiKeySet && (
              <button
                id="prompt-optimizer-api-key-clear"
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

      <div>
        <FieldLabel>{t("promptOptimizerPrompt")}</FieldLabel>
        <TextArea
          id="prompt-optimizer-prompt-input"
          value={server.prompt}
          onInput={(e) => update({ prompt: e.currentTarget.value })}
          onBlur={() => void saveSettings({ prompt: server.prompt })}
          rows={5}
        />
        <p className="mt-1 text-[12px] leading-relaxed text-fg-muted">
          {t("promptOptimizerPromptHint")}
        </p>
      </div>

      <p className="flex items-center gap-1.5 text-[12px] leading-relaxed text-fg-muted">
        <span id="prompt-optimizer-settings-status" className="font-mono text-[11px]">
          {state === "saved" ? "✓" : state === "error" ? "✗" : ""}
        </span>
        <span>{t("promptOptimizerServerShared")}</span>
      </p>
    </div>
  );
}
