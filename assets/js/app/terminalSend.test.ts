import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resolveSendMode, sendComposedText } from "./terminalSend";

describe("resolveSendMode", () => {
  it("keeps an explicit strategy", () => {
    expect(resolveSendMode("delayed", true)).toBe("delayed");
    expect(resolveSendMode("bracketed-delayed", false)).toBe("bracketed-delayed");
  });

  it("falls back on the terminal's bracketed-paste mode", () => {
    expect(resolveSendMode(undefined, true)).toBe("bracketed");
    expect(resolveSendMode(undefined, false)).toBe("inline");
  });
});

describe("sendComposedText", () => {
  let pushed: string[];
  const push = (data: string) => pushed.push(data);

  beforeEach(() => {
    pushed = [];
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("inline: body and CR go out immediately", () => {
    sendComposedText("ls", true, "inline", push);
    expect(pushed).toEqual(["ls", "\r"]);
  });

  it("inline without submit sends only the body", () => {
    sendComposedText("ls", false, "inline", push);
    expect(pushed).toEqual(["ls"]);
  });

  it("bracketed: wraps the body in paste markers with an immediate CR", () => {
    sendComposedText("a\nb", true, "bracketed", push);
    expect(pushed).toEqual(["\x1b[200~a\nb\x1b[201~", "\r"]);
  });

  it("delayed: CR follows 50ms after the body", () => {
    sendComposedText("hi", true, "delayed", push);
    expect(pushed).toEqual(["hi"]);
    vi.advanceTimersByTime(50);
    expect(pushed).toEqual(["hi", "\r"]);
  });

  it("bracketed-delayed: CR follows 300ms after the wrapped body", () => {
    sendComposedText("hi", true, "bracketed-delayed", push);
    expect(pushed).toEqual(["\x1b[200~hi\x1b[201~"]);
    vi.advanceTimersByTime(299);
    expect(pushed).toHaveLength(1);
    vi.advanceTimersByTime(1);
    expect(pushed).toEqual(["\x1b[200~hi\x1b[201~", "\r"]);
  });

  it("sends a ! mode prefix alone first, body 50ms later", () => {
    sendComposedText("!make test", true, "delayed", push);
    expect(pushed).toEqual(["!"]);
    vi.advanceTimersByTime(50);
    expect(pushed).toEqual(["!", "make test"]);
    vi.advanceTimersByTime(50);
    expect(pushed).toEqual(["!", "make test", "\r"]);
  });

  it("does not split the prefix in bracketed modes", () => {
    sendComposedText("&job", false, "bracketed", push);
    expect(pushed).toEqual(["\x1b[200~&job\x1b[201~"]);
  });

  it("a lone ! is not treated as a prefix", () => {
    sendComposedText("!", true, "inline", push);
    expect(pushed).toEqual(["!", "\r"]);
  });

  it("empty body with submit is a bare Enter", () => {
    sendComposedText("", true, "delayed", push);
    expect(pushed).toEqual([]);
    vi.advanceTimersByTime(50);
    expect(pushed).toEqual(["\r"]);
  });
});
