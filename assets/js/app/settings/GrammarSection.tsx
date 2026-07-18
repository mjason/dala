import React, { useEffect, useRef, useState } from "react";
import { deleteEntry, syntaxGrammars } from "../../ash_rpc";
import { call } from "../rpc";
import { useI18n } from "../i18n";
import { uploadMultipartFile, loadUploadLimits } from "../fileUpload";
import { clearGrammarCache, type GrammarInfo } from "../cm/textmate";
import { FieldLabel } from "../ui";

/**
 * Global TextMate grammar management (the "上传的地方"): `.tmLanguage.json`
 * files uploaded here land in the server's data directory and apply to
 * every project. Project-scoped grammars live in each project's
 * `dala.jsonc` instead and are only listed contextually in the editor.
 */
export default function GrammarSection({ onError }: { onError: (message: string) => void }) {
  const { t } = useI18n();
  const [globalDir, setGlobalDir] = useState<string | null>(null);
  const [grammars, setGrammars] = useState<GrammarInfo[]>([]);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const refresh = async (): Promise<string | null> => {
    const result = await call<{ globalDir: string; grammars: GrammarInfo[] }>(syntaxGrammars, {
      input: {},
      fields: ["globalDir", "grammars"] as never,
    });
    if (!mountedRef.current) return null;
    if (!result.ok) {
      onError(result.error || t("somethingWentWrong"));
      return null;
    }
    setGlobalDir(result.data.globalDir);
    setGrammars(result.data.grammars);
    return result.data.globalDir;
  };

  useEffect(() => {
    void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const upload = async (files: FileList | null) => {
    const batch = Array.from(files ?? []);
    if (batch.length === 0 || busy) return;
    setBusy(true);
    // The destination comes from the server; fetch it on demand instead of
    // silently dropping an upload that raced the initial load.
    const dir = globalDir ?? (await refresh());
    if (!dir) {
      setBusy(false);
      return;
    }
    try {
      const { drawerUpload } = await loadUploadLimits();
      for (const file of batch) {
        try {
          await uploadMultipartFile({
            url: "/files/upload",
            file,
            fields: { dir },
            maxBytes: drawerUpload.maxBytes,
            maxLabel: drawerUpload.maxLabel,
          });
        } catch (error) {
          onError(error instanceof Error ? error.message : t("uploadFailed"));
        }
      }
      clearGrammarCache();
      await refresh();
    } finally {
      if (mountedRef.current) setBusy(false);
    }
  };

  const remove = async (path: string) => {
    const result = await call<unknown>(deleteEntry, { input: { path }, fields: ["path"] });
    if (!result.ok) return onError(result.error || t("somethingWentWrong"));
    clearGrammarCache();
    await refresh();
  };

  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between gap-2">
        <FieldLabel>{t("grammarSection")}</FieldLabel>
        <button
          id="grammar-upload-button"
          disabled={busy || !globalDir}
          onClick={() => inputRef.current?.click()}
          className="inline-flex items-center gap-1.5 rounded-lg border border-mint/50 px-3 py-1.5 text-[13px] text-mint transition-colors hover:bg-mint/10 disabled:opacity-50"
        >
          + {t("grammarUpload")}
        </button>
        <input
          ref={inputRef}
          type="file"
          accept=".json"
          multiple
          className="hidden"
          onChange={(e) => {
            void upload(e.target.files);
            e.target.value = "";
          }}
        />
      </div>
      <p className="text-xs leading-5 text-fg-muted">{t("grammarHint")}</p>
      {grammars.length === 0 ? (
        <div className="rounded-lg border border-line px-3 py-2 text-xs text-fg-muted">
          {t("grammarEmpty")}
        </div>
      ) : (
        <div className="divide-y divide-line rounded-lg border border-line">
          {grammars.map((g) => (
            <div key={g.path} data-grammar-row={g.path} className="flex items-center gap-2 px-3 py-2">
              <div className="min-w-0 flex-1">
                <div className="truncate text-[13px] text-fg">{g.name}</div>
                <div className="truncate font-mono text-[11px] text-fg-muted">
                  {g.scopeName} · {g.extensions.join(" ") || "—"}
                </div>
              </div>
              <button
                data-grammar-delete={g.path}
                onClick={() => void remove(g.path)}
                title={t("deleteEntry")}
                className="grid h-6 w-6 shrink-0 place-items-center rounded text-fg-muted transition-colors hover:text-danger"
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
