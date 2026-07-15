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
import { popWindow, pushWindow } from "./shortcuts";

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

function Harness({
  root,
  initialValue = "",
  focusNonce = 0,
  onClose = () => {},
}: {
  root: string;
  initialValue?: string;
  focusNonce?: number;
  onClose?: () => void;
}) {
  const [value, setValue] = useState(initialValue);
  return (
    <I18nProvider>
      <InputBar
        sessionId="s1"
        root={root}
        app="claude"
        value={value}
        onChange={setValue}
        focusNonce={focusNonce}
        focusConsumed={0}
        onFocusConsumed={() => {}}
        onSend={() => {}}
        onClose={onClose}
        onError={() => {}}
        onLayoutReady={() => {}}
        onResize={() => {}}
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

describe("InputBar fullscreen mode", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    agentCommands.mockResolvedValue({ success: true, data: { app: "claude", commands: [] } });
    listFiles.mockResolvedValue(filesResult([]));
  });

  it("toggles with #composer-fullscreen; a spacer keeps the terminal's layout", () => {
    render(<Harness root="/proj" />);
    const button = document.querySelector("#composer-fullscreen")!;
    expect(button).not.toBeNull();

    fireEvent.click(button);
    expect(document.querySelector("#input-bar")!.getAttribute("data-fullscreen")).toBe("true");
    // The bar left the flow — the spacer holds its slot so the terminal
    // behind the overlay never reflows.
    expect(document.querySelector("#input-bar-spacer")).not.toBeNull();

    fireEvent.click(button);
    expect(document.querySelector("#input-bar")!.getAttribute("data-fullscreen")).toBeNull();
    expect(document.querySelector("#input-bar-spacer")).toBeNull();
  });

  it("Escape exits fullscreen first — the composer stays open", () => {
    const onClose = vi.fn();
    render(<Harness root="/proj" onClose={onClose} />);
    fireEvent.click(document.querySelector("#composer-fullscreen")!);

    fireEvent.keyDown(window, { key: "Escape" });

    expect(document.querySelector("#input-bar")!.getAttribute("data-fullscreen")).toBeNull();
    expect(onClose).not.toHaveBeenCalled();
    expect(document.querySelector("#composer-editor")).not.toBeNull();
  });

  it("Escape belongs to the topmost window — one stacked above fullscreen wins", () => {
    render(<Harness root="/proj" />);
    fireEvent.click(document.querySelector("#composer-fullscreen")!);
    const token = pushWindow();
    try {
      fireEvent.keyDown(window, { key: "Escape" });
      expect(document.querySelector("#input-bar")!.getAttribute("data-fullscreen")).toBe("true");
    } finally {
      popWindow(token);
    }
  });
});

describe("InputBar scroll-to-cursor on open", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    agentCommands.mockResolvedValue({ success: true, data: { app: "claude", commands: [] } });
    listFiles.mockResolvedValue(filesResult([]));
  });

  it("mounting with a draft scrolls the end-of-draft cursor into view", async () => {
    const spy = vi.spyOn(EditorView, "scrollIntoView");
    const draft = Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\n");
    render(<Harness root="/proj" initialValue={draft} focusNonce={1} />);

    // jsdom can't measure heights, but the scroll request itself must be
    // dispatched (after the initial layout tick) and target the draft's end.
    await waitFor(() => expect(spy).toHaveBeenCalled());
    const positions = spy.mock.calls.map((c) => c[0]);
    expect(positions).toContain(draft.length);
    expect(editorView().state.selection.main.head).toBe(draft.length);
  });

  it("mounting with an empty draft requests no scroll", async () => {
    const spy = vi.spyOn(EditorView, "scrollIntoView");
    render(<Harness root="/proj" />);
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(spy).not.toHaveBeenCalled();
  });
});
