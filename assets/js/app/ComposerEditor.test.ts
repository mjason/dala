import { describe, expect, it } from "vitest";
import { consumeLocalValue } from "./ComposerEditor";

describe("ComposerEditor controlled value synchronization", () => {
  it("does not treat delayed parent echoes as external edits", () => {
    const pending = ["h", "he", "hel", "hell", "hello"];

    expect(consumeLocalValue(pending, "he")).toBe(true);
    expect(pending).toEqual(["hel", "hell", "hello"]);
    expect(consumeLocalValue(pending, "hello")).toBe(true);
    expect(pending).toEqual([]);
  });

  it("leaves a genuinely external value for the editor to apply", () => {
    const pending = ["messy prompt"];

    expect(consumeLocalValue(pending, "Clear prompt.")).toBe(false);
    expect(pending).toEqual(["messy prompt"]);
  });
});
