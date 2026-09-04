import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

afterEach(() => {
  cleanup();
});

// jsdom ships no layout engine, so it never implemented Range.getClientRects.
// CodeMirror measures text by calling textRange(...).getClientRects() inside a
// requestAnimationFrame callback; in jsdom that throws asynchronously, and the
// stray rejection is attributed to whichever suite happens to be running when
// the frame fires (typically InputBar's editor mount). Mirror jsdom's own
// "no layout" answer for elements — an empty rect list — so the measure resolves
// to zero size instead of throwing. Guarded so a future jsdom that implements
// these wins.
if (typeof Range !== "undefined") {
  if (typeof Range.prototype.getClientRects !== "function") {
    Range.prototype.getClientRects = function getClientRects(): DOMRectList {
      const list = {
        length: 0,
        item: () => null,
        [Symbol.iterator]: function* () {},
      };
      return list as unknown as DOMRectList;
    };
  }
  if (typeof Range.prototype.getBoundingClientRect !== "function") {
    Range.prototype.getBoundingClientRect = function getBoundingClientRect(): DOMRect {
      return {
        x: 0,
        y: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        width: 0,
        height: 0,
        toJSON: () => ({}),
      } as DOMRect;
    };
  }
}
