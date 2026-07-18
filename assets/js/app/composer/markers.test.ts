import { describe, expect, it } from "vitest";
import {
  appendWithSpace,
  createMarker,
  pathsText,
  replaceMarkerIn,
  stripMarkers,
} from "./markers";

describe("createMarker", () => {
  it("is unique and matches the strip pattern", () => {
    const a = createMarker();
    const b = createMarker();
    expect(a).not.toBe(b);
    expect(stripMarkers(`x ${a} y ${b} z`)).toBe("x y z");
  });
});

describe("stripMarkers", () => {
  it("removes markers with their trailing space, leaves other text intact", () => {
    expect(stripMarkers("看这张图 ⟨upload:7⟩ 和这段")).toBe("看这张图 和这段");
    expect(stripMarkers("⟨upload:1⟩")).toBe("");
    expect(stripMarkers("no markers here")).toBe("no markers here");
  });

  it("does not touch lookalike user text", () => {
    expect(stripMarkers("upload:3 and ⟨upload:x⟩")).toBe("upload:3 and ⟨upload:x⟩");
  });
});

describe("replaceMarkerIn", () => {
  it("replaces the first occurrence in place", () => {
    expect(replaceMarkerIn("a ⟨upload:2⟩ b", "⟨upload:2⟩", "/tmp/x.png ")).toBe("a /tmp/x.png  b");
  });

  it("null when the marker is gone", () => {
    expect(replaceMarkerIn("a b", "⟨upload:2⟩", "x")).toBeNull();
  });
});

describe("appendWithSpace", () => {
  it("adds exactly one separating space", () => {
    expect(appendWithSpace("hello", "/tmp/a.png ")).toBe("hello /tmp/a.png ");
    expect(appendWithSpace("hello ", "/tmp/a.png ")).toBe("hello /tmp/a.png ");
    expect(appendWithSpace("", "/tmp/a.png ")).toBe("/tmp/a.png ");
    expect(appendWithSpace("line\n", "x")).toBe("line\nx");
  });

  it("appending nothing changes nothing", () => {
    expect(appendWithSpace("hello", "")).toBe("hello");
  });
});

describe("pathsText", () => {
  it("joins with spaces and adds the trailing typing gap", () => {
    expect(pathsText(["/a.png", "/b.png"])).toBe("/a.png /b.png ");
    expect(pathsText([])).toBe("");
  });
});
