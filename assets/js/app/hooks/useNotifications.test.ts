import { describe, expect, it } from "vitest";
import { agentEventBody, agentStateFor, IMPORTANT_AGENT_EVENTS } from "./useNotifications";

describe("agentStateFor", () => {
  it("maps attention events", () => {
    expect(agentStateFor("permission_request")).toBe("attention");
    expect(agentStateFor("question_asked")).toBe("attention");
    expect(agentStateFor("idle_prompt")).toBe("attention");
  });

  it("maps working events", () => {
    expect(agentStateFor("prompt_submit")).toBe("working");
    expect(agentStateFor("tool_complete")).toBe("working");
    expect(agentStateFor("session_start")).toBe("working");
  });

  it("maps done events", () => {
    expect(agentStateFor("stop")).toBe("done");
    expect(agentStateFor("notify")).toBe("done");
  });

  it("returns null for anything else", () => {
    expect(agentStateFor("unknown_event")).toBeNull();
    expect(agentStateFor("")).toBeNull();
  });
});

describe("IMPORTANT_AGENT_EVENTS", () => {
  it("covers exactly the notification-worthy events", () => {
    expect(IMPORTANT_AGENT_EVENTS).toEqual([
      "stop",
      "permission_request",
      "question_asked",
      "idle_prompt",
      "notify",
    ]);
  });
});

describe("agentEventBody", () => {
  const t = (key: string) => `[${key}]`;

  it("prefers the agent's summary, then the query", () => {
    expect(agentEventBody({ summary: "did it", query: "q?", event: "stop" }, t)).toBe("did it");
    expect(agentEventBody({ summary: null, query: "q?", event: "stop" }, t)).toBe("q?");
  });

  it("falls back to a per-event generic line", () => {
    expect(agentEventBody({ summary: null, query: null, event: "stop" }, t)).toBe("[agentEventStop]");
    expect(agentEventBody({ summary: null, query: null, event: "idle_prompt" }, t)).toBe("[agentEventIdle]");
    expect(agentEventBody({ summary: null, query: null, event: "question_asked" }, t)).toBe("[agentEventQuestion]");
    expect(agentEventBody({ summary: null, query: null, event: "permission_request" }, t)).toBe("[agentEventPermission]");
  });
});
