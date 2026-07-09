import React, { useEffect, useRef, useState } from "react";
import type { Channel } from "phoenix";
import { getSocket } from "./socket";
import { useI18n } from "./i18n";
import { applyUpdate, toPermission } from "./agentUpdates";
import type { AgentMessage, Permission } from "./agentUpdates";

type Props = {
  sessionId: string;
  onError: (message: string) => void;
};

type Status = "starting" | "ready" | "exited";

export default function AgentView({ sessionId, onError }: Props) {
  const { t } = useI18n();
  const [messages, setMessages] = useState<AgentMessage[]>([]);
  const [permission, setPermission] = useState<Permission | null>(null);
  const [status, setStatus] = useState<Status>("starting");
  const [busy, setBusy] = useState(false);
  const [input, setInput] = useState("");
  const channelRef = useRef<Channel | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const onErrorRef = useRef(onError);
  onErrorRef.current = onError;

  useEffect(() => {
    const socket = getSocket();
    const channel = socket.channel(`agent:${sessionId}`, {}) as unknown as Channel;
    channelRef.current = channel;

    channel.on("ready", () => setStatus("ready"));
    channel.on("user_prompt", (p: { text: string }) =>
      setMessages((m) => [...m, { kind: "user", text: p.text }]),
    );
    channel.on("update", (p: { update: unknown }) =>
      setMessages((m) => applyUpdate(m, p.update)),
    );
    channel.on("permission", (p) => setPermission(toPermission(p)));
    channel.on("turn_end", () => setBusy(false));
    channel.on("error", (p: { message?: string }) => {
      setBusy(false);
      onErrorRef.current(p.message ?? "agent error");
    });
    channel.on("exit", () => {
      setBusy(false);
      setStatus("exited");
    });

    channel
      .join()
      .receive("ok", (resp: { status?: Status }) => {
        if (resp?.status) setStatus(resp.status);
      })
      .receive("error", () => onErrorRef.current(t("agentNotReady")));

    return () => {
      channel.leave();
      channelRef.current = null;
    };
  }, [sessionId, t]);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
  }, [messages, permission]);

  const send = () => {
    const text = input.trim();
    if (!text || status !== "ready" || busy) return;
    channelRef.current?.push("prompt", { text });
    setInput("");
    setBusy(true);
  };

  const answerPermission = (optionId: string) => {
    if (!permission) return;
    channelRef.current?.push("permission", { requestId: permission.requestId, optionId });
    setPermission(null);
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div ref={scrollRef} id="agent-messages" className="flex-1 space-y-3 overflow-y-auto p-3">
        {messages.length === 0 && status === "ready" && (
          <div className="mt-8 text-center text-[13px] text-fg-muted">{t("agentEmptyHint")}</div>
        )}
        {status === "starting" && (
          <div className="mt-8 text-center text-[13px] text-fg-muted">{t("agentConnecting")}</div>
        )}
        {messages.map((m, i) => (
          <MessageBubble key={i} message={m} t={t} />
        ))}
      </div>

      {permission && (
        <div id="agent-permission" className="border-t border-line bg-bg2/50 p-3">
          <div className="mb-2 font-mono text-xs text-fg-muted">
            {t("permissionPrompt")}
            {permission.title ? ` · ${permission.title}` : ""}
          </div>
          <div className="flex flex-wrap gap-2">
            {permission.options.map((o) => (
              <button
                key={o.optionId}
                data-option={o.optionId}
                onClick={() => answerPermission(o.optionId)}
                className={`rounded-md border px-2.5 py-1 font-mono text-xs transition-colors ${
                  o.kind.startsWith("allow")
                    ? "border-mint/50 text-mint hover:bg-mint/10"
                    : "border-line text-fg-muted hover:border-danger/50 hover:text-danger"
                }`}
              >
                {o.name}
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="border-t border-line p-2">
        <div className="flex items-end gap-2">
          <textarea
            id="agent-input"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                send();
              }
            }}
            placeholder={status === "exited" ? t("agentExited") : t("agentInputPlaceholder")}
            disabled={status !== "ready"}
            rows={2}
            className="min-h-0 flex-1 resize-none rounded-md border border-line bg-bg0 px-2.5 py-1.5 font-mono text-[13px] text-fg outline-none transition-colors placeholder:text-fg-muted/60 focus:border-mint/60 disabled:opacity-50"
          />
          {busy ? (
            <button
              id="agent-cancel"
              onClick={() => channelRef.current?.push("cancel", {})}
              className="shrink-0 rounded-md border border-line px-3 py-2 font-mono text-xs text-fg-muted transition-colors hover:border-danger/50 hover:text-danger"
            >
              {t("stop")}
            </button>
          ) : (
            <button
              id="agent-send"
              onClick={send}
              disabled={status !== "ready" || !input.trim()}
              className="shrink-0 rounded-md bg-mint px-3 py-2 font-mono text-xs font-medium text-black transition-colors hover:brightness-110 disabled:opacity-40"
            >
              {t("send")}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function MessageBubble({
  message,
  t,
}: {
  message: AgentMessage;
  t: (key: any) => string;
}) {
  if (message.kind === "user") {
    return (
      <div className="ml-auto max-w-[85%] rounded-lg border border-mint/30 bg-mint/5 px-3 py-2 text-[13px] text-fg [overflow-wrap:anywhere] whitespace-pre-wrap">
        {message.text}
      </div>
    );
  }
  if (message.kind === "assistant") {
    return (
      <div className="max-w-[92%] whitespace-pre-wrap px-1 text-[13px] leading-6 text-fg [overflow-wrap:anywhere]">
        {message.text}
      </div>
    );
  }
  if (message.kind === "thought") {
    return (
      <div className="max-w-[92%] whitespace-pre-wrap px-1 text-[12px] italic leading-5 text-fg-muted/80 [overflow-wrap:anywhere]">
        {message.text}
      </div>
    );
  }
  // tool
  return (
    <div className="flex items-center gap-2 rounded-md border border-line bg-bg2/40 px-2.5 py-1.5 font-mono text-xs">
      <span className="text-[#6d9fd6]">{message.toolKind}</span>
      <span className="min-w-0 flex-1 truncate text-fg">{message.title}</span>
      <StatusDot status={message.status} />
      <span className="shrink-0 text-fg-muted">{message.status}</span>
    </div>
  );
}

function StatusDot({ status }: { status: string }) {
  const color =
    status === "completed"
      ? "bg-mint"
      : status === "failed"
        ? "bg-danger"
        : status === "in_progress"
          ? "bg-[#d9a860] animate-pulse"
          : "bg-fg-muted/50";
  return <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${color}`} />;
}
