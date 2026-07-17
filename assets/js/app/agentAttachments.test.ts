import { describe, expect, it } from "vitest";
import { extractAgentAttachments, splitAgentAttachments } from "./agentAttachments";

const first =
  "/home/mj/.local/share/dala/tmp/attachments/f85984c1-686b-43c6-a6d1-129d436b2db2/image.png";
const second =
  "/home/mj/.local/share/dala/tmp/attachments/06216102-fbca-4280-92dd-42304deb6d2a/screenshot.webp";

describe("extractAgentAttachments", () => {
  it("extracts a managed browser attachment from prompt text", () => {
    expect(extractAgentAttachments(`分析这个图片 ${first}`)).toEqual({
      paths: [first],
      rest: "分析这个图片",
    });
  });

  it("extracts multiple managed attachments in their original order", () => {
    expect(extractAgentAttachments(`${first} ${second} 对比这两张图`)).toEqual({
      paths: [first, second],
      rest: "对比这两张图",
    });
  });

  it("keeps compatibility with legacy dala-paste paths", () => {
    const legacy = "/tmp/dala-paste/paste-20260716-120000-a1b2c3.png";
    expect(extractAgentAttachments(`${legacy} describe it`)).toEqual({
      paths: [legacy],
      rest: "describe it",
    });
  });

  it("does not extract ordinary absolute paths", () => {
    const prompt = "查看 /home/user/project/image.png 并修复布局";
    expect(extractAgentAttachments(prompt)).toEqual({ paths: [], rest: prompt });
  });

  it("rejects attachment-like paths without a canonical UUID", () => {
    const prompt = "/home/mj/.local/share/dala/tmp/attachments/1/image.png";
    expect(extractAgentAttachments(prompt)).toEqual({ paths: [], rest: prompt });
  });
});

describe("splitAgentAttachments", () => {
  const A = "/home/mj/.local/share/dala/tmp/attachments/be2a5687-6874-47aa-a03e-bf5939c4387d/a.png";
  const B = "/home/mj/.local/share/dala/tmp/attachments/2874d11a-b4a9-4f59-90dd-4cc508832b36/b.png";

  it("preserves the original interleaving of text and attachments", () => {
    const segments = splitAgentAttachments(`look at ${A} and then ${B} thanks`);
    expect(segments).toEqual([
      { type: "text", value: "look at" },
      { type: "path", value: A },
      { type: "text", value: "and then" },
      { type: "path", value: B },
      { type: "text", value: "thanks" },
    ]);
  });

  it("returns a single text run when nothing is attached", () => {
    expect(splitAgentAttachments("just words")).toEqual([{ type: "text", value: "just words" }]);
  });
});
