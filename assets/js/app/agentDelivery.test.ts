import { describe, expect, it } from "vitest";
import { planDelivery, resolveApp } from "./agentDelivery";

const IMG1 = "/home/mj/.local/share/dala/tmp/attachments/8b956328-65e9-4cb3-bf2c-dfcb9ffb5aa6/image.png";
const IMG2 = "/home/mj/.local/share/dala/tmp/attachments/4de6e8b7-755d-4fb3-bd22-418bc6001a33/image.png";
const TXT = "/home/mj/.local/share/dala/tmp/attachments/4de6e8b7-755d-4fb3-bd22-418bc6001a33/notes.md";

describe("resolveApp", () => {
  it("trusts a positive detection", () => {
    expect(resolveApp("codex", "claude")).toBe("codex");
  });

  it("falls back to the OSC-recorded agent when detection misses", () => {
    expect(resolveApp("unknown", "claude")).toBe("claude");
    expect(resolveApp("shell", "opencode")).toBe("opencode");
  });

  it("keeps the detection when there is no recorded agent", () => {
    expect(resolveApp("shell", null)).toBe("shell");
    expect(resolveApp("unknown", "weird")).toBe("unknown");
  });
});

describe("planDelivery — no attachments", () => {
  it("plain shell text is one step with no strategy", () => {
    expect(planDelivery("shell", "ls -la", true)).toEqual([
      { text: "ls -la", submit: true, strategy: undefined },
    ]);
  });

  it("codex gets bracketed, copilot bracketed-delayed", () => {
    expect(planDelivery("codex", "hi", true)[0].strategy).toBe("bracketed");
    expect(planDelivery("copilot", "hi", true)[0].strategy).toBe("bracketed-delayed");
  });

  it("claude/opencode/gemini: delayed for one line, bracketed-delayed for multiline", () => {
    for (const app of ["claude", "opencode", "gemini"]) {
      expect(planDelivery(app, "one line", true)[0].strategy).toBe("delayed");
      expect(planDelivery(app, "two\nlines", true)[0].strategy).toBe("bracketed-delayed");
    }
  });

  it("submit=false is passed through", () => {
    expect(planDelivery("claude", "draft", false)).toEqual([
      { text: "draft", submit: false, strategy: "delayed" },
    ]);
  });
});

describe("planDelivery — interleaved attachments (the core regression)", () => {
  it("a leading image stays leading: path, then text, then trailing path, then submit", () => {
    const steps = planDelivery("claude", `${IMG1} 还有这个问题\n${IMG2}`, true);
    expect(steps.map((s) => s.text)).toEqual([
      `${IMG1} `,
      "还有这个问题 ",
      `${IMG2} `,
      "",
    ]);
    // Every path goes out as its own bracketed paste so the agent chips it.
    expect(steps[0].strategy).toBe("bracketed");
    expect(steps[2].strategy).toBe("bracketed");
    // Only the last step submits.
    expect(steps.map((s) => s.submit)).toEqual([false, false, false, true]);
  });

  it("paths and text keep pacing gaps for the agent TUI", () => {
    const steps = planDelivery("claude", `${IMG1} hello`, true);
    expect(steps[0].waitAfterMs).toBe(200);
    expect(steps[1].waitAfterMs).toBe(120);
    expect(steps[2].waitAfterMs).toBeUndefined();
  });

  it("text files get an @ prefix on claude/gemini but not codex/opencode; images never do", () => {
    expect(planDelivery("claude", `${TXT} summarize`, true)[0].text).toBe(`@${TXT} `);
    expect(planDelivery("gemini", `${TXT} summarize`, true)[0].text).toBe(`@${TXT} `);
    expect(planDelivery("codex", `${TXT} summarize`, true)[0].text).toBe(`${TXT} `);
    expect(planDelivery("opencode", `${TXT} summarize`, true)[0].text).toBe(`${TXT} `);
    expect(planDelivery("claude", `${IMG1} look`, true)[0].text).toBe(`${IMG1} `);
  });

  it("REGRESSION: attachment paths still interleave when app detection fails mid-task", () => {
    // The tty's foreground group was a spawned tool → app: "unknown". The
    // old code fell back to one plain paste and the agent moved every image
    // to the end of the message.
    const steps = planDelivery("unknown", `${IMG1} 图在开头`, true);
    expect(steps.map((s) => s.text)).toEqual([`${IMG1} `, "图在开头 ", ""]);
    expect(steps[0].strategy).toBe("bracketed");
  });

  it("multiline text runs inside an interleave are bracketed", () => {
    const steps = planDelivery("claude", `line1\nline2 ${IMG1}`, true);
    const textStep = steps.find((s) => s.text.includes("line1"))!;
    expect(textStep.strategy).toBe("bracketed");
  });

  it("ordinary project paths do NOT trigger interleaving", () => {
    const steps = planDelivery("claude", "look at /home/mj/dev/app/src/main.py please", true);
    expect(steps).toHaveLength(1);
  });

  it("submit=false interleaves without a final submit step", () => {
    const steps = planDelivery("claude", `${IMG1} note`, false);
    expect(steps.every((s) => !s.submit)).toBe(true);
    expect(steps.map((s) => s.text)).toEqual([`${IMG1} `, "note "]);
  });
});
