import React, { useCallback, useEffect, useState } from "react";
import {
  buildCSRFHeaders,
  createAgentSession,
  deleteAgentSession,
  listAgentSessions,
} from "../ash_rpc";
import { useI18n } from "./i18n";
import AgentView from "./AgentView";
import { shortPath } from "./util";
import { acpAgents } from "./meta";

const FIELDS = ["id", "name", "cwd", "status", "insertedAt"] as const;

export type AgentSession = {
  id: string;
  name: string;
  cwd: string;
  status: "starting" | "ready" | "exited";
  insertedAt: string;
};

type Props = {
  cwd: string;
  onError: (message: string) => void;
};

export default function AgentPanel({ cwd, onError }: Props) {
  const { t } = useI18n();
  const [sessions, setSessions] = useState<AgentSession[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);

  const load = useCallback(async () => {
    const result = await listAgentSessions({
      fields: [...FIELDS],
      headers: buildCSRFHeaders(),
    });
    if (result.success) {
      const list = result.data as unknown as AgentSession[];
      setSessions(list);
      setActiveId((cur) => cur ?? list[list.length - 1]?.id ?? null);
    } else {
      onError(result.errors[0]?.message ?? t("couldNotLoadAgents"));
    }
  }, [onError, t]);

  useEffect(() => {
    void load();
  }, [load]);

  const create = async (kind?: string) => {
    setMenuOpen(false);
    setCreating(true);
    const result = await createAgentSession({
      input: kind
        ? { name: t("agentDefaultName"), cwd, agentKind: kind }
        : { name: t("agentDefaultName"), cwd },
      fields: [...FIELDS],
      headers: buildCSRFHeaders(),
    });
    setCreating(false);
    if (result.success) {
      const session = result.data as unknown as AgentSession;
      setSessions((list) => [...list, session]);
      setActiveId(session.id);
    } else {
      onError(result.errors[0]?.message ?? t("couldNotCreateAgent"));
    }
  };

  // One installed agent → create directly; several → let the user pick.
  const startNew = () => {
    if (acpAgents.length <= 1) void create(acpAgents[0]?.id);
    else setMenuOpen((v) => !v);
  };

  const remove = async (id: string) => {
    const result = await deleteAgentSession({ identity: id, headers: buildCSRFHeaders() });
    if (result.success) {
      setSessions((list) => list.filter((s) => s.id !== id));
      setActiveId((cur) => (cur === id ? null : cur));
    } else {
      onError(result.errors[0]?.message ?? t("somethingWentWrong"));
    }
  };

  return (
    <div id="agent-panel" className="flex h-full min-h-0 flex-col bg-bg1">
      <div className="flex items-center gap-1 overflow-x-auto border-b border-line px-2 py-1.5">
        <span className="mr-1 shrink-0 font-mono text-xs font-medium uppercase tracking-wider text-fg-muted">
          AI
        </span>
        {sessions.map((s) => (
          <div
            key={s.id}
            className={`group flex shrink-0 items-center gap-1.5 rounded-md border px-2 py-1 text-xs transition-colors ${
              s.id === activeId
                ? "border-mint/50 bg-bg2 text-fg"
                : "border-line text-fg-muted hover:text-fg"
            }`}
          >
            <button
              data-agent-tab={s.id}
              onClick={() => setActiveId(s.id)}
              className="flex items-center gap-1.5"
            >
              <span
                className={`h-1.5 w-1.5 rounded-full ${
                  s.status === "ready"
                    ? "bg-mint"
                    : s.status === "exited"
                      ? "bg-fg-muted/50"
                      : "bg-[#d9a860] animate-pulse"
                }`}
              />
              <span className="max-w-[10rem] truncate font-mono">{s.name}</span>
            </button>
            <button
              onClick={() => void remove(s.id)}
              className="opacity-0 transition-opacity hover:text-danger group-hover:opacity-100"
              title={t("close")}
            >
              ✕
            </button>
          </div>
        ))}
        <div className="relative shrink-0">
          <button
            id="new-agent-button"
            onClick={startNew}
            disabled={creating}
            className="rounded-md border border-line px-2 py-1 font-mono text-xs text-fg-muted transition-colors hover:border-mint/50 hover:text-mint disabled:opacity-50"
            title={t("newAgent")}
          >
            +
          </button>
          {menuOpen && (
            <>
              <div className="fixed inset-0 z-40" onClick={() => setMenuOpen(false)} />
              <div className="absolute right-0 top-full z-50 mt-1 w-44 rounded-lg border border-line bg-bg1 py-1 shadow-2xl">
                {acpAgents.map((a) => (
                  <button
                    key={a.id}
                    data-agent-kind={a.id}
                    onClick={() => void create(a.id)}
                    className="flex w-full items-center px-3 py-1.5 text-left font-mono text-[13px] text-fg transition-colors hover:bg-bg2/70"
                  >
                    {a.name}
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      </div>

      {activeId ? (
        <AgentView key={activeId} sessionId={activeId} onError={onError} />
      ) : (
        <div className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
          <p className="text-[13px] text-fg-muted">{t("noAgentsHint")}</p>
          <p className="font-mono text-[11px] text-fg-muted/70">{shortPath(cwd, 40)}</p>
          <div className="flex flex-wrap justify-center gap-2">
            {acpAgents.map((a) => (
              <button
                key={a.id}
                data-agent-kind={a.id}
                onClick={() => void create(a.id)}
                disabled={creating}
                className="rounded-md bg-mint px-3 py-1.5 text-[13px] font-medium text-black transition-colors hover:brightness-110 disabled:opacity-50"
              >
                {a.name}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
