import React from "react";
import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { FileRow } from "./fileRows";

describe("GitPanel status theme tokens", () => {
  it("keeps textual state labels and maps every state to its semantic theme colour", () => {
    const states = [
      ["A ", "A", "text-git-added"],
      [" M", "M", "text-git-modified"],
      [" D", "D", "text-git-deleted"],
      ["R ", "R", "text-git-renamed"],
      ["??", "U", "text-git-untracked"],
      ["UU", "!", "text-git-conflict"],
    ] as const;

    const { container } = render(
      <>
        {states.map(([status], index) => (
          <FileRow
            key={status}
            file={{ path: `file-${index}.txt`, status, staged: false, unstaged: true }}
            busy={null}
            onOpen={vi.fn()}
            actions={[]}
          />
        ))}
      </>,
    );

    const badges = container.querySelectorAll(".font-semibold");
    expect(badges).toHaveLength(states.length);
    states.forEach(([_status, label, className], index) => {
      expect(badges[index]).toHaveTextContent(label);
      expect(badges[index]).toHaveClass(className);
    });
  });
});
