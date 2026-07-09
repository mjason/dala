import { describe, expect, it } from "vitest";
import { detectDelimiter, parseCsv } from "./csv";

describe("parseCsv", () => {
  it("parses simple rows", () => {
    expect(parseCsv("a,b,c\n1,2,3\n")).toEqual([
      ["a", "b", "c"],
      ["1", "2", "3"],
    ]);
  });

  it("handles quoted fields with commas and escaped quotes", () => {
    expect(parseCsv('name,quote\n"Doe, John","said ""hi"""\n')).toEqual([
      ["name", "quote"],
      ["Doe, John", 'said "hi"'],
    ]);
  });

  it("handles newlines inside quoted fields", () => {
    expect(parseCsv('a,b\n"line1\nline2",x\n')).toEqual([
      ["a", "b"],
      ["line1\nline2", "x"],
    ]);
  });

  it("handles CRLF line endings", () => {
    expect(parseCsv("a,b\r\n1,2\r\n")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });

  it("handles empty fields and a missing trailing newline", () => {
    expect(parseCsv("a,,c\n,,")).toEqual([
      ["a", "", "c"],
      ["", "", ""],
    ]);
  });

  it("supports alternative delimiters", () => {
    expect(parseCsv("a;b\n1;2", ";")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
    expect(parseCsv("a\tb\n1\t2", "\t")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });
});

describe("detectDelimiter", () => {
  it("prefers tabs for .tsv files", () => {
    expect(detectDelimiter("a,b\tc", "data.tsv")).toBe("\t");
  });

  it("detects semicolons", () => {
    expect(detectDelimiter("a;b;c\n1;2;3")).toBe(";");
  });

  it("defaults to comma", () => {
    expect(detectDelimiter("a,b,c")).toBe(",");
    expect(detectDelimiter("no delimiters here")).toBe(",");
  });
});
