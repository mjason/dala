import { describe, expect, it } from "vitest";
import { formatDate } from "./HistoryView";

describe("formatDate", () => {
  it("formats an ISO timestamp as YYYY-MM-DD", () => {
    // midday UTC keeps the calendar day stable in any test timezone
    expect(formatDate("2026-07-09T12:04:05Z")).toBe("2026-07-09");
  });

  it("zero-pads month and day", () => {
    expect(formatDate("2026-01-02T12:00:00Z")).toBe("2026-01-02");
  });

  it("returns an empty string for unparseable input", () => {
    expect(formatDate("not-a-date")).toBe("");
    expect(formatDate("")).toBe("");
  });
});
