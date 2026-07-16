import React from "react";
import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n";

const gitStatus = vi.hoisted(() => vi.fn());
vi.mock("../../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  gitStatus,
}));

import { useGitStatus } from "./useGitStatus";

function wrapper({ children }: { children: React.ReactNode }) {
  return <I18nProvider>{children}</I18nProvider>;
}

function outcome(path: string) {
  return {
    success: true,
    data: {
      repo: true,
      root: "/proj",
      branch: "main",
      files: [{ path, status: " M", staged: false, unstaged: true }],
    },
  };
}

describe("useGitStatus", () => {
  beforeEach(() => {
    gitStatus.mockReset();
  });

  it("does not let an older request overwrite a newer status snapshot", async () => {
    let resolveFirst!: (value: ReturnType<typeof outcome>) => void;
    const first = new Promise<ReturnType<typeof outcome>>((resolve) => {
      resolveFirst = resolve;
    });
    gitStatus.mockReturnValueOnce(first).mockResolvedValueOnce(outcome("newer.ex"));

    const { result } = renderHook(
      () => useGitStatus("/proj", () => {}, { watch: false, pollMs: 0 }),
      { wrapper },
    );
    await waitFor(() => expect(gitStatus).toHaveBeenCalledTimes(1));

    await act(async () => {
      await result.current.loadStatus(true);
    });
    expect(result.current.status?.files[0]?.path).toBe("newer.ex");

    await act(async () => {
      resolveFirst(outcome("older.ex"));
      await first;
    });
    expect(result.current.status?.files[0]?.path).toBe("newer.ex");
  });
});
