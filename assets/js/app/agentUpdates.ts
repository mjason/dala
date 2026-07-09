/**
 * Pure reducers for an agent conversation, factored out of the React
 * component so the streaming/accumulation logic can be unit-tested.
 */

export type AgentMessage =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "thought"; text: string }
  | { kind: "tool"; id: string; title: string; toolKind: string; status: string };

export type Permission = {
  requestId: number;
  title: string;
  options: { optionId: string; name: string; kind: string }[];
};

/** Append text to the last message if it has the same role, else start one. */
function appendText(
  msgs: AgentMessage[],
  kind: "user" | "assistant" | "thought",
  text: string,
): AgentMessage[] {
  if (!text) return msgs;
  const last = msgs[msgs.length - 1];
  if (last && last.kind === kind) {
    const next = msgs.slice(0, -1);
    next.push({ kind, text: last.text + text });
    return next;
  }
  return [...msgs, { kind, text }];
}

/** Apply one ACP `session/update` block to the message list. */
export function applyUpdate(msgs: AgentMessage[], update: any): AgentMessage[] {
  const t = update?.sessionUpdate;
  switch (t) {
    case "agent_message_chunk":
      return appendText(msgs, "assistant", update.content?.text ?? "");
    case "user_message_chunk":
      return appendText(msgs, "user", update.content?.text ?? "");
    case "agent_thought_chunk":
      return appendText(msgs, "thought", update.content?.text ?? "");
    case "tool_call":
      return [
        ...msgs,
        {
          kind: "tool",
          id: update.toolCallId,
          title: update.title ?? update.toolCallId ?? "tool",
          toolKind: update.kind ?? "other",
          status: update.status ?? "pending",
        },
      ];
    case "tool_call_update":
      return msgs.map((m) =>
        m.kind === "tool" && m.id === update.toolCallId
          ? { ...m, status: update.status ?? m.status }
          : m,
      );
    default:
      return msgs;
  }
}

/** Build a Permission from a `permission` channel event payload. */
export function toPermission(payload: any): Permission {
  return {
    requestId: payload.requestId,
    title: payload.toolCall?.title ?? "",
    options: (payload.options ?? []).map((o: any) => ({
      optionId: o.optionId,
      name: o.name ?? o.optionId,
      kind: o.kind ?? "",
    })),
  };
}
