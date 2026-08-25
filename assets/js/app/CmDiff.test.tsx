import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import CmDiff from "./CmDiff";

describe("CmDiff hunk actions", () => {
  it("mounts action buttons with their patch callbacks intact", async () => {
    const onClick = vi.fn();

    render(
      <CmDiff
        oldText={"old\n"}
        newText={"new\n"}
        mode="split"
        wrap={true}
        filename="sample.txt"
        chunkActions={[{ label: "Stage hunk", kind: "primary", onClick }]}
      />,
    );

    const button = await screen.findByRole("button", { name: "Stage hunk" });
    button.click();
    expect(onClick).toHaveBeenCalledWith(
      expect.objectContaining({
        forward: expect.stringContaining("@@"),
        reverse: expect.stringContaining("@@"),
      }),
    );
  });
});
