import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { I18nProvider } from "./i18n";

const gitStatus = vi.fn();
const gitDiff = vi.fn();
const gitLog = vi.fn();
const gitShow = vi.fn();
const gitStage = vi.fn();
const gitUnstage = vi.fn();
const gitDiscard = vi.fn();
const gitCommit = vi.fn();
const gitBranches = vi.fn();
const gitCheckout = vi.fn();

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  gitStatus: (...a: unknown[]) => gitStatus(...a),
  gitDiff: (...a: unknown[]) => gitDiff(...a),
  gitLog: (...a: unknown[]) => gitLog(...a),
  gitShow: (...a: unknown[]) => gitShow(...a),
  gitStage: (...a: unknown[]) => gitStage(...a),
  gitUnstage: (...a: unknown[]) => gitUnstage(...a),
  gitDiscard: (...a: unknown[]) => gitDiscard(...a),
  gitCommit: (...a: unknown[]) => gitCommit(...a),
  gitBranches: (...a: unknown[]) => gitBranches(...a),
  gitCheckout: (...a: unknown[]) => gitCheckout(...a),
}));

import GitPanel from "./GitPanel";

class FakeSocket {
  static OPEN = 1;
  static last: FakeSocket | null = null;
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  readyState = FakeSocket.OPEN;

  constructor() {
    FakeSocket.last = this;
  }
  send() {}
  close() {
    this.readyState = 3;
  }
}

const ok = (data: unknown) => ({ success: true, data });

function statusData(files: object[], branch = "main") {
  return { repo: true, root: "/proj", branch, files };
}

function renderPanel(overrides: Partial<React.ComponentProps<typeof GitPanel>> = {}) {
  const props = { path: "/proj", onClose: vi.fn(), onError: vi.fn(), ...overrides };
  render(
    <I18nProvider>
      <GitPanel {...props} />
    </I18nProvider>,
  );
  return props;
}

beforeEach(() => {
  localStorage.clear();
  [
    gitStatus,
    gitDiff,
    gitLog,
    gitShow,
    gitStage,
    gitUnstage,
    gitDiscard,
    gitCommit,
    gitBranches,
    gitCheckout,
  ].forEach((m) => m.mockReset());
  vi.spyOn(window, "confirm").mockReturnValue(true);
  FakeSocket.last = null;
  vi.stubGlobal("WebSocket", FakeSocket as unknown as typeof WebSocket);
  vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) =>
    setTimeout(() => cb(0), 0),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("GitPanel changes tab", () => {
  it("groups staged and unstaged files and shows the branch", async () => {
    gitStatus.mockResolvedValue(
      ok(
        statusData([
          { path: "staged.ex", status: "M ", staged: true, unstaged: false },
          { path: "work.ex", status: " M", staged: false, unstaged: true },
        ]),
      ),
    );

    renderPanel();

    expect(await screen.findByText("main")).toBeInTheDocument();
    expect(screen.getByText("staged.ex")).toBeInTheDocument();
    expect(screen.getByText("work.ex")).toBeInTheDocument();
  });

  it("reloads status automatically when the repository watcher reports a change", async () => {
    gitStatus
      .mockResolvedValueOnce(
        ok(statusData([{ path: "work.ex", status: " M", staged: false, unstaged: true }])),
      )
      .mockResolvedValueOnce(ok(statusData([])));

    renderPanel();
    await screen.findByText("work.ex");
    await waitFor(() => expect(FakeSocket.last).not.toBeNull());

    await act(async () => {
      FakeSocket.last!.onmessage?.({ data: JSON.stringify({ changed: "/proj" }) });
      await new Promise((resolve) => setTimeout(resolve, 220));
    });

    await waitFor(() => expect(gitStatus).toHaveBeenCalledTimes(2));
    expect(screen.queryByText("work.ex")).not.toBeInTheDocument();
    expect(screen.getByText("Working tree clean")).toBeInTheDocument();
  });

  it("stages a file and reloads status", async () => {
    gitStatus
      .mockResolvedValueOnce(ok(statusData([{ path: "new.txt", status: "??", staged: false, unstaged: true }])))
      .mockResolvedValueOnce(ok(statusData([{ path: "new.txt", status: "A ", staged: true, unstaged: false }])));
    gitStage.mockResolvedValue(ok(true));

    renderPanel();

    await screen.findByText("new.txt");
    fireEvent.click(screen.getByTitle("Stage"));

    await waitFor(() =>
      expect(gitStage).toHaveBeenCalledWith(
        expect.objectContaining({ input: { path: "/proj", file: "new.txt" } }),
      ),
    );
    await waitFor(() => expect(gitStatus).toHaveBeenCalledTimes(2));
  });

  it("confirms before discarding", async () => {
    gitStatus.mockResolvedValue(
      ok(statusData([{ path: "work.ex", status: " M", staged: false, unstaged: true }])),
    );
    gitDiscard.mockResolvedValue(ok(true));

    renderPanel();
    await screen.findByText("work.ex");
    fireEvent.click(screen.getByTitle("Discard"));

    expect(window.confirm).toHaveBeenCalled();
    await waitFor(() =>
      expect(gitDiscard).toHaveBeenCalledWith(
        expect.objectContaining({ input: { path: "/proj", file: "work.ex" } }),
      ),
    );
  });

  it("commits the staged files with a message", async () => {
    gitStatus.mockResolvedValue(
      ok(statusData([{ path: "staged.ex", status: "M ", staged: true, unstaged: false }])),
    );
    gitCommit.mockResolvedValue(ok({ hash: "abc123" }));

    renderPanel();
    await screen.findByText("staged.ex");

    const button = document.getElementById("commit-button") as HTMLButtonElement;
    expect(button.disabled).toBe(true); // no message yet

    fireEvent.change(document.getElementById("commit-message-input")!, {
      target: { value: "my commit" },
    });
    expect(button.disabled).toBe(false);

    fireEvent.click(button);
    await waitFor(() =>
      expect(gitCommit).toHaveBeenCalledWith(
        expect.objectContaining({ input: { path: "/proj", message: "my commit", amend: false } }),
      ),
    );
  });

  it("opens a structured diff for a file", async () => {
    gitStatus.mockResolvedValue(
      ok(statusData([{ path: "lib/app.ex", status: " M", staged: false, unstaged: true }])),
    );
    gitDiff.mockResolvedValue(
      ok({
        diff: "diff --git a/lib/app.ex b/lib/app.ex\n--- a/lib/app.ex\n+++ b/lib/app.ex\n@@ -1 +1 @@\n-old\n+new\n",
        binary: false,
        truncated: false,
      }),
    );

    renderPanel();
    fireEvent.click(await screen.findByText("lib/app.ex"));

    await waitFor(() => {
      const view = document.getElementById("diff-view");
      expect(view).not.toBeNull();
      expect(view!.textContent).toContain("new");
    });
    // structured view exposes inline/split switch
    expect(document.querySelector('[data-diff-mode="split"]')).not.toBeNull();
  });
});

describe("GitPanel branches", () => {
  it("lists branches and checks out another one", async () => {
    gitStatus.mockResolvedValue(ok(statusData([])));
    gitBranches.mockResolvedValue(
      ok({
        current: "main",
        local: [
          { name: "feature", current: false },
          { name: "main", current: true },
        ],
        remote: [{ name: "origin/main", current: false }],
      }),
    );
    gitCheckout.mockResolvedValue(ok(true));

    renderPanel();
    await screen.findByText("main");

    fireEvent.click(document.getElementById("branch-menu-button")!);
    await waitFor(() => expect(document.getElementById("branch-menu")).not.toBeNull());
    expect(document.querySelector('[data-branch="feature"]')).not.toBeNull();
    expect(document.querySelector('[data-branch="origin/main"]')).not.toBeNull();

    fireEvent.click(document.querySelector('[data-branch="feature"]')!);
    await waitFor(() =>
      expect(gitCheckout).toHaveBeenCalledWith(
        expect.objectContaining({ input: { path: "/proj", name: "feature" } }),
      ),
    );
    // status is reloaded after the switch
    await waitFor(() => expect(gitStatus.mock.calls.length).toBeGreaterThan(1));
  });
});

describe("GitPanel history tab", () => {
  it("lists commits and opens a commit patch", async () => {
    gitStatus.mockResolvedValue(ok(statusData([])));
    gitLog.mockResolvedValue(
      ok({
        commits: [
          { hash: "aaa111", author: "MJ", date: "2026-07-08T10:00:00Z", subject: "recent" },
          { hash: "bbb222", author: "MJ", date: "2026-07-01T10:00:00Z", subject: "older" },
        ],
      }),
    );
    gitShow.mockResolvedValue(ok({ text: "commit aaa111\n+added line\n", truncated: false }));

    renderPanel();
    fireEvent.click(await screen.findByRole("button", { name: /History/ }));

    expect(await screen.findByText("recent")).toBeInTheDocument();
    expect(screen.getByText("older")).toBeInTheDocument();

    fireEvent.click(screen.getByText("recent"));
    await waitFor(() =>
      expect(gitShow).toHaveBeenCalledWith(
        expect.objectContaining({ input: { path: "/proj", hash: "aaa111" } }),
      ),
    );
    await waitFor(() =>
      expect(document.getElementById("diff-view")?.textContent).toContain("added line"),
    );
  });

  it("shows a file rail for multi-file commits and filters by file", async () => {
    const patch = [
      "commit aaa111",
      "diff --git a/first.ex b/first.ex",
      "--- a/first.ex",
      "+++ b/first.ex",
      "@@ -1 +1 @@",
      "-old one",
      "+new one",
      "diff --git a/second.ex b/second.ex",
      "--- a/second.ex",
      "+++ b/second.ex",
      "@@ -1 +1 @@",
      "-old two",
      "+new two",
      "",
    ].join("\n");

    gitStatus.mockResolvedValue(ok(statusData([])));
    gitLog.mockResolvedValue(
      ok({
        commits: [{ hash: "aaa111", author: "MJ", date: "2026-07-08T10:00:00Z", subject: "multi" }],
      }),
    );
    gitShow.mockResolvedValue(ok({ text: patch, truncated: false }));

    renderPanel();
    fireEvent.click(await screen.findByRole("button", { name: /History/ }));
    fireEvent.click(await screen.findByText("multi"));

    await waitFor(() => expect(document.getElementById("commit-file-list")).not.toBeNull());
    const diffView = () => document.getElementById("diff-view")!.textContent!;
    expect(diffView()).toContain("new one");
    expect(diffView()).toContain("new two");

    fireEvent.click(document.querySelector('[data-commit-file="second.ex"]')!);
    await waitFor(() => {
      expect(diffView()).toContain("new two");
      expect(diffView()).not.toContain("new one");
    });
  });
});
