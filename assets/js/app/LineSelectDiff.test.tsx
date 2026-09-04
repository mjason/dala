import React from "react";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { I18nProvider } from "./i18n";
import LineSelectDiff from "./LineSelectDiff";
import type { ChunkAction } from "./CmDiff";

const oldText = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n";
const newText = "one\ntwo\nthree\nFOUR!\nFIVE!\nextra\nsix\nseven\n";

function renderDiff(actions: ChunkAction[]) {
  render(
    <I18nProvider>
      <LineSelectDiff
        oldText={oldText}
        newText={newText}
        filename="a.txt"
        wrap={false}
        actions={actions}
      />
    </I18nProvider>,
  );
}

function stageAction(onClick = vi.fn()): ChunkAction {
  return { label: "Stage hunk", lineLabel: "Stage selected lines", kind: "primary", onClick };
}

describe("LineSelectDiff", () => {
  it("renders changed lines with checkboxes and disabled actions", () => {
    renderDiff([stageAction()]);

    expect(document.querySelectorAll('[data-line-row="del"]')).toHaveLength(2);
    expect(document.querySelectorAll('[data-line-row="add"]')).toHaveLength(3);

    const button = screen.getByRole("button", { name: /Stage selected lines \(0\)/ });
    expect(button).toBeDisabled();
  });

  it("toggling lines enables the action and builds a partial patch", () => {
    const onClick = vi.fn();
    renderDiff([stageAction(onClick)]);

    // Select the "-four" and "+FOUR!" rows by clicking them.
    fireEvent.click(document.querySelectorAll('[data-line-row="del"]')[0]!);
    fireEvent.click(document.querySelectorAll('[data-line-row="add"]')[0]!);

    const button = screen.getByRole("button", { name: /Stage selected lines \(2\)/ });
    expect(button).toBeEnabled();
    fireEvent.click(button);

    expect(onClick).toHaveBeenCalledTimes(1);
    const [patch, source] = onClick.mock.calls[0];
    expect(source).toBe("lines");
    expect(patch.forward).toContain("-four");
    expect(patch.forward).toContain("+FOUR!");
    expect(patch.forward).toContain(" five"); // unselected removal → context
    expect(patch.forward).not.toContain("FIVE!"); // unselected addition → dropped
    expect(patch.reverse).toContain("-FOUR!");
    expect(patch.reverse).toContain("+four");
  });

  it("select-all checkbox selects every line of the chunk", () => {
    renderDiff([stageAction()]);

    const [selectAll] = document.querySelectorAll('[data-line-chunk] header input[type="checkbox"]');
    fireEvent.click(selectAll!);

    expect(screen.getByRole("button", { name: /Stage selected lines \(5\)/ })).toBeEnabled();
    expect(document.querySelectorAll("[data-selected]")).toHaveLength(5);

    fireEvent.click(selectAll!);
    expect(screen.getByRole("button", { name: /Stage selected lines \(0\)/ })).toBeDisabled();
  });
});
