import type { RefObject } from "react";
import type { AgentEventPayload } from "../../ash_types";
import type { Session } from "../Sidebar";
import { AGENT_LABELS } from "../InputBar";
import { notificationsEnabled } from "../notifyPrefs";
import { useI18n } from "../i18n";

/** Sidebar-dot state derived from an OSC 777 agent event; null = no change. */
export function agentStateFor(
  event: string,
): "working" | "attention" | "done" | null {
  return ["permission_request", "question_asked", "idle_prompt"].includes(event)
    ? ("attention" as const)
    : ["prompt_submit", "tool_complete", "session_start"].includes(event)
      ? ("working" as const)
      : ["stop", "notify"].includes(event)
        ? ("done" as const)
        : null;
}

/** Events worth a system notification when the user is elsewhere. */
export const IMPORTANT_AGENT_EVENTS = [
  "stop",
  "permission_request",
  "question_asked",
  "idle_prompt",
  "notify",
];

type Translate = (key: "agentEventStop" | "agentEventIdle" | "agentEventQuestion" | "agentEventPermission") => string;

/** Notification body: the agent's own words when present, a generic line otherwise. */
export function agentEventBody(
  p: Pick<AgentEventPayload, "summary" | "query" | "event">,
  t: Translate,
): string {
  return (
    p.summary ||
    p.query ||
    (p.event === "stop"
      ? t("agentEventStop")
      : p.event === "idle_prompt"
        ? t("agentEventIdle")
        : p.event === "question_asked"
          ? t("agentEventQuestion")
          : t("agentEventPermission"))
  );
}

/**
 * System notification dispatch for agent events: skipped while the user is
 * looking at the session; native client bridge when present, Notification
 * API (with permission dance) otherwise, toast as the last resort.
 */
export function useNotifications(opts: {
  activeIdRef: RefObject<string | null>;
  sessionsRef: RefObject<Session[]>;
  toast: (message: string) => void;
  onJump: (id: string) => void;
}) {
  const { activeIdRef, sessionsRef, toast, onJump } = opts;
  const { t } = useI18n();

  const notifyAgentEvent = (p: AgentEventPayload) => {
    // Notify when the user is elsewhere (other session, other window).
    if (!notificationsEnabled()) return;
    if (!IMPORTANT_AGENT_EVENTS.includes(p.event)) return;
    if (!document.hidden && p.id === activeIdRef.current) return;
    const session = sessionsRef.current.find((s) => s.id === p.id);
    const title = `${AGENT_LABELS[p.agent] ?? p.agent} · ${session?.name ?? "dala"}`;
    const body = agentEventBody(p, t);
    // Inside the desktop client, use the OS's own notifications (Notification
    // Center / Windows toasts) via the preload bridge — no permission prompt,
    // native look. Click-to-jump comes back as a "dala:notify-click" event.
    const nativeNotify = (
      window as { __DALA_NOTIFY__?: (p: { title: string; body: string; tag: string }) => Promise<unknown> }
    ).__DALA_NOTIFY__;
    if (nativeNotify) {
      void nativeNotify({ title, body, tag: p.id });
      return;
    }
    const show = () => {
      const n = new Notification(title, { body, tag: `dala-agent-${p.id}` });
      n.onclick = () => {
        window.focus();
        onJump(p.id);
        n.close();
      };
    };
    if (typeof Notification !== "undefined" && Notification.permission === "granted") {
      show();
    } else if (typeof Notification !== "undefined" && Notification.permission === "default") {
      void Notification.requestPermission().then((perm) => {
        if (perm === "granted") show();
        else toast(`${title}: ${body}`);
      });
    } else {
      toast(`${title}: ${body}`);
    }
  };

  return { notifyAgentEvent };
}
