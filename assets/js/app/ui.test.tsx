import { describe, expect, it } from "vitest";
import { createRoot } from "react-dom/client";
import { act } from "react";
import React from "react";
import { TextArea, TextInput, Select, cx, inputClass } from "./ui";

function render(node: React.ReactElement): HTMLElement {
  const host = document.createElement("div");
  document.body.appendChild(host);
  act(() => createRoot(host).render(node));
  return host;
}

describe("shared form-control primitives", () => {
  it("cx joins truthy parts only", () => {
    expect(cx("a", false, undefined, "b", null)).toBe("a b");
  });

  it("TextInput carries the shared visual spec plus caller layout classes", () => {
    const host = render(<TextInput id="t1" className="max-w-40" />);
    const el = host.querySelector<HTMLInputElement>("#t1")!;
    for (const token of inputClass.split(" ")) expect(el.className).toContain(token);
    expect(el.className).toContain("max-w-40");
  });

  it("TextArea adds resize-y on top of the shared spec", () => {
    const host = render(<TextArea id="t2" rows={3} />);
    const el = host.querySelector<HTMLTextAreaElement>("#t2")!;
    expect(el.className).toContain("resize-y");
    expect(el.rows).toBe(3);
    expect(el.className).toContain("focus:border-mint/60");
  });

  it("Select shares the same spec so all controls stay visually in sync", () => {
    const host = render(
      <Select id="t3">
        <option value="a">A</option>
      </Select>,
    );
    const el = host.querySelector<HTMLSelectElement>("#t3")!;
    expect(el.className).toContain("border-line");
    expect(el.className).toContain("text-[13px]");
  });

  it("native props (value/onChange/placeholder) pass straight through", () => {
    let value = "";
    const host = render(
      <TextInput id="t4" placeholder="hint" defaultValue="x" onChange={(e) => (value = e.target.value)} />,
    );
    const el = host.querySelector<HTMLInputElement>("#t4")!;
    expect(el.placeholder).toBe("hint");
    act(() => {
      // Go through the native setter so React's value tracker sees the
      // change (a plain el.value assignment gets deduped as a no-op).
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(el, "typed");
      el.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(value).toBe("typed");
  });
});
