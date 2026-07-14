import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

// jsdom does not implement Range geometry; CodeMirror measures text through
// it after animation frames, including after a test has already unmounted.
if (!Range.prototype.getClientRects) {
  Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
}

afterEach(() => {
  cleanup();
});
