import React, { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, waitFor } from "@testing-library/react";
import { EditorView } from "@codemirror/view";
import { I18nProvider } from "./i18n";

const listFiles = vi.fn();
const agentCommands = vi.fn();

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  listFiles: (...args: unknown[]) => listFiles(...args),
  agentCommands: (...args: unknown[]) => agentCommands(...args),
  savePastedFile: vi.fn(),
  transcribe: vi.fn(),
}));

import InputBar from "./InputBar";

/** The CodeMirror view inside the composer host div. */
function editorView(): EditorView {
  const content = document.querySelector("#composer-editor .cm-content");
  const view = content && EditorView.findFromDOM(content as HTMLElement);
  if (!view) throw new Error("composer editor view not found");
  return view;
}

function typeDraft(text: string) {
  const view = editorView();
  act(() => {
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: text },
      selection: { anchor: text.length },
    });
  });
}

function Harness({ root }: { root: string }) {
  const [value, setValue] = useState("");
  return (
    <I18nProvider>
      <InputBar
        sessionId="s1"
        root={root}
        app="claude"
        value={value}
        onChange={setValue}
        focusNonce={0}
        focusConsumed={0}
        onFocusConsumed={() => {}}
        onSend={() => {}}
        onClose={() => {}}
        onError={() => {}}
      />
    </I18nProvider>
  );
}

function filesResult(files: string[], truncated = false) {
  return { success: true, data: { root: "/proj", files, truncated } };
}

describe("InputBar @-mention", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    agentCommands.mockResolvedValue({ success: true, data: { app: "claude", commands: [] } });
  });

  it("matches a typed full absolute path against root-relative candidates", async () => {
    listFiles.mockResolvedValue(filesResult(["lib/foo.ex", "lib/bar.ex"]));
    render(<Harness root="/proj" />);

    typeDraft("@/proj/lib/foo.ex");

    await waitFor(() => {
      expect(document.querySelector('[data-mention-item="lib/foo.ex"]')).not.toBeNull();
    });
  });

  it("shows a truncated hint at the bottom of the mention menu", async () => {
    listFiles.mockResolvedValue(filesResult(["lib/foo.ex"], true));
    render(<Harness root="/proj" />);

    typeDraft("@foo");

    await waitFor(() => {
      expect(document.querySelector("#mention-truncated")).not.toBeNull();
    });
  });

  it("shows the truncated hint even when nothing matches (explains the miss)", async () => {
    listFiles.mockResolvedValue(filesResult(["lib/foo.ex"], true));
    render(<Harness root="/proj" />);

    typeDraft("@zzzznothing");

    await waitFor(() => {
      expect(document.querySelector("#mention-truncated")).not.toBeNull();
    });
    expect(document.querySelectorAll("[data-mention-item]")).toHaveLength(0);
  });

  it("shows no hint when the list is complete", async () => {
    listFiles.mockResolvedValue(filesResult(["lib/foo.ex"], false));
    render(<Harness root="/proj" />);

    typeDraft("@foo");

    await waitFor(() => {
      expect(document.querySelector('[data-mention-item="lib/foo.ex"]')).not.toBeNull();
    });
    expect(document.querySelector("#mention-truncated")).toBeNull();
  });

  it("inserts picked paths with backslash-escaped whitespace", async () => {
    const spaced = "strategies/选币 研究demo.py";
    listFiles.mockResolvedValue(filesResult([spaced]));
    render(<Harness root="/proj" />);

    // The mention token can't contain spaces, so the user types the
    // collapsed query; the pick must still insert a usable reference.
    typeDraft("@选币研究");
    await waitFor(() => {
      expect(document.querySelector(`[data-mention-item="${spaced}"]`)).not.toBeNull();
    });

    act(() => {
      fireEvent.mouseDown(document.querySelector(`[data-mention-item="${spaced}"]`)!);
    });

    // Bare spaces would cut the @-reference short in claude AND in a shell;
    // backslash-escaping is the convention both accept.
    await waitFor(() => {
      expect(editorView().state.doc.toString()).toBe("@strategies/选币\\ 研究demo.py ");
    });
  });

  it("resets and refetches the file list when the root changes", async () => {
    listFiles.mockResolvedValue(filesResult(["a.txt"]));
    const { rerender } = render(<Harness root="/proj" />);

    typeDraft("@a");
    await waitFor(() => expect(listFiles).toHaveBeenCalledTimes(1));
    expect(listFiles.mock.calls[0][0]).toMatchObject({ input: { path: "/proj" } });

    rerender(<Harness root="/elsewhere" />);

    // The old root's list is stale: it must be dropped and refetched.
    await waitFor(() => expect(listFiles).toHaveBeenCalledTimes(2));
    expect(listFiles.mock.calls[1][0]).toMatchObject({ input: { path: "/elsewhere" } });
  });
});
