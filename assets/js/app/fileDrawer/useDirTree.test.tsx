import { act, renderHook, waitFor } from "@testing-library/react";
import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n";
import { useDirTree } from "./useDirTree";

const listDirectoryMock = vi.hoisted(() => vi.fn());
vi.mock("../../ash_rpc", () => ({
  listDirectory: listDirectoryMock,
  buildCSRFHeaders: () => ({}),
}));

/** A WebSocket stand-in whose frames the test drives by hand. */
class FakeSocket {
  static last: FakeSocket | null = null;
  static OPEN = 1;
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  readyState = 1;
  sent: string[] = [];

  constructor() {
    FakeSocket.last = this;
  }
  send(data: string) {
    this.sent.push(data);
  }
  close() {
    this.readyState = 3;
  }
}

const listing = (path: string) => ({
  success: true,
  data: { path, parent: "/", entries: [{ name: "a.txt", dir: false, size: 1 }] },
});

function wrapper({ children }: { children: React.ReactNode }) {
  return <I18nProvider>{children}</I18nProvider>;
}

describe("useDirTree — change-storm handling", () => {
  beforeEach(() => {
    listDirectoryMock.mockReset();
    listDirectoryMock.mockImplementation(({ input }: { input: { path: string } }) =>
      Promise.resolve(listing(input.path)),
    );
    vi.stubGlobal("WebSocket", FakeSocket as unknown as typeof WebSocket);
    // Run rAF callbacks on a macrotask so the hook's storm flush is observable.
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) =>
      setTimeout(() => cb(0), 0),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("a burst of changed frames for one expanded ancestor costs ONE refetch", async () => {
    const { result } = renderHook(() => useDirTree("/proj", () => {}), { wrapper });

    // Initial root load.
    await waitFor(() => expect(result.current.root?.path).toBe("/proj"));
    const afterMount = listDirectoryMock.mock.calls.length;

    const socket = FakeSocket.last!;
    act(() => socket.onopen?.());

    // 100 nested paths under the (expanded) root — a `git checkout` storm.
    await act(async () => {
      for (let i = 0; i < 100; i++) {
        socket.onmessage?.({ data: JSON.stringify({ changed: `/proj/src/pkg${i}` }) });
      }
      await new Promise((r) => setTimeout(r, 5));
    });

    const stormCalls = listDirectoryMock.mock.calls.length - afterMount;
    expect(stormCalls).toBe(1);
    expect(listDirectoryMock.mock.calls.at(-1)?.[0].input.path).toBe("/proj");
  });

  it("restores a root's expanded folders after the drawer path leaves and returns", async () => {
    const { result, rerender } = renderHook(({ p }) => useDirTree(p, () => {}), {
      wrapper,
      initialProps: { p: "/proj" },
    });
    await waitFor(() => expect(result.current.root?.path).toBe("/proj"));

    // Expand a subdirectory under /proj.
    await act(async () => {
      await result.current.toggleDir("/proj/lib");
    });
    expect(result.current.expanded.has("/proj/lib")).toBe(true);

    // Switch the drawer to another session's cwd — a fresh, collapsed tree.
    rerender({ p: "/other" });
    await waitFor(() => expect(result.current.root?.path).toBe("/other"));
    expect(result.current.expanded.has("/proj/lib")).toBe(false);

    // Switch back — /proj's tree is restored with `lib` still expanded.
    rerender({ p: "/proj" });
    await waitFor(() => expect(result.current.root?.path).toBe("/proj"));
    expect(result.current.expanded.has("/proj/lib")).toBe(true);
  });

  it("malformed frames are ignored and do not refetch", async () => {
    const { result } = renderHook(() => useDirTree("/proj", () => {}), { wrapper });
    await waitFor(() => expect(result.current.root?.path).toBe("/proj"));
    const afterMount = listDirectoryMock.mock.calls.length;

    const socket = FakeSocket.last!;
    await act(async () => {
      socket.onmessage?.({ data: "not json" });
      socket.onmessage?.({ data: JSON.stringify({ nope: true }) });
      await new Promise((r) => setTimeout(r, 5));
    });

    expect(listDirectoryMock.mock.calls.length).toBe(afterMount);
  });
});
