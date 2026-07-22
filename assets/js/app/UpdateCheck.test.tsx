import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, waitFor } from "@testing-library/react";
import UpdateCheck from "./UpdateCheck";
import { I18nProvider } from "./i18n";

const rpc = vi.hoisted(() => ({
  checkUpdate: vi.fn(),
  applyUpdate: vi.fn(),
  updateStatus: vi.fn(),
}));

const socket = vi.hoisted(() => {
  let reconnect: (() => void) | null = null;

  return {
    onReconnect: vi.fn((callback: () => void) => {
      reconnect = callback;
      return vi.fn();
    }),
    reconnect: () => reconnect?.(),
    reset: () => {
      reconnect = null;
    },
  };
});

vi.mock("../ash_rpc", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  ...rpc,
}));

vi.mock("./meta", () => ({ serverVersion: "0.25.11" }));
vi.mock("./socket", () => ({ onReconnect: socket.onReconnect }));

const attemptId = "6ba7b810-9dad-41d1-80b4-00c04fd430c8";
const otherAttemptId = "23f66c23-9b6e-4c76-b28d-f553c583c529";
const target = "v0.25.12";
const storageKey = "dala:update-attempt";

const info = (overrides: Record<string, unknown> = {}) => ({
  success: true,
  data: {
    enabled: true,
    current: "0.25.11",
    latest: "0.25.11",
    tag: "v0.25.11",
    updateAvailable: false,
    notesUrl: null,
    legacyEnvConfig: false,
    ...overrides,
  },
});

const updateInfo = () =>
  info({
    latest: "0.25.12",
    tag: target,
    updateAvailable: true,
  });

const status = (overrides: Record<string, unknown> = {}) => ({
  success: true,
  data: {
    attemptId,
    status: "pending",
    target,
    message: null,
    rolledBack: null,
    startedAt: new Date().toISOString(),
    completedAt: null,
    ...overrides,
  },
});

beforeEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.clearAllMocks();
  socket.reset();
  sessionStorage.clear();
  localStorage.clear();
  vi.spyOn(globalThis.crypto, "randomUUID").mockReturnValue(attemptId);
  rpc.checkUpdate.mockResolvedValue(info());
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

function renderCheck() {
  return render(
    <I18nProvider>
      <UpdateCheck />
    </I18nProvider>,
  );
}

async function startUpdate() {
  rpc.checkUpdate.mockResolvedValue(updateInfo());
  renderCheck();

  await waitFor(() => expect(document.querySelector("#update-now-button")).not.toBeNull());
  fireEvent.click(document.querySelector("#update-now-button")!);
}

describe("UpdateCheck config-migration nudge", () => {
  it("legacy env mode shows the migration notice linking to the guide", async () => {
    rpc.checkUpdate.mockResolvedValue(info({ legacyEnvConfig: true }));
    renderCheck();
    await waitFor(() =>
      expect(document.querySelector("#config-migrate-notice")).not.toBeNull(),
    );
    const link = document.querySelector<HTMLAnchorElement>("#config-migrate-notice")!;
    expect(link.href).toContain("config-migration");
  });

  it("config-file installs see no notice", async () => {
    rpc.checkUpdate.mockResolvedValue(info());
    renderCheck();
    await waitFor(() => expect(rpc.checkUpdate).toHaveBeenCalled());
    expect(document.querySelector("#config-migrate-notice")).toBeNull();
  });
});

describe("UpdateCheck authoritative update result", () => {
  it("persists and sends the client attempt id before apply settles", async () => {
    rpc.applyUpdate.mockImplementation(() => new Promise(() => undefined));
    rpc.updateStatus.mockResolvedValue(status({ status: "unknown", target: null }));

    await startUpdate();

    await waitFor(() =>
      expect(rpc.applyUpdate).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { attemptId, expectedTarget: target },
        }),
      ),
    );
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toEqual({
      attemptId,
      target,
      requestedAt: expect.any(String),
    });
    await waitFor(() =>
      expect(rpc.updateStatus).toHaveBeenCalledWith(
        expect.objectContaining({ input: { attemptId } }),
      ),
    );
  });

  it("normalizes the generated attempt id to canonical lowercase", async () => {
    vi.mocked(globalThis.crypto.randomUUID).mockReturnValue(
      attemptId.toUpperCase() as ReturnType<Crypto["randomUUID"]>,
    );
    rpc.applyUpdate.mockImplementation(() => new Promise(() => undefined));
    rpc.updateStatus.mockResolvedValue(status({ status: "unknown", target: null }));

    await startUpdate();

    await waitFor(() =>
      expect(rpc.applyUpdate).toHaveBeenCalledWith(
        expect.objectContaining({ input: { attemptId, expectedTarget: target } }),
      ),
    );
  });

  it("generates a canonical v4 attempt id when randomUUID is unavailable", async () => {
    const fallbackAttemptId = "00010203-0405-4607-8809-0a0b0c0d0e0f";
    const getRandomValues = vi.fn((bytes: Uint8Array) => {
      bytes.set(Array.from({ length: 16 }, (_value, index) => index));
      return bytes;
    });
    vi.stubGlobal("crypto", { randomUUID: undefined, getRandomValues });
    rpc.applyUpdate.mockImplementation(() => new Promise(() => undefined));
    rpc.updateStatus.mockResolvedValue(
      status({ attemptId: fallbackAttemptId, status: "unknown", target: null }),
    );

    await startUpdate();

    await waitFor(() =>
      expect(rpc.applyUpdate).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { attemptId: fallbackAttemptId, expectedTarget: target },
        }),
      ),
    );
    expect(getRandomValues).toHaveBeenCalledTimes(1);
  });

  it("does not report success or health-poll the old server after the helper is only scheduled", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    rpc.applyUpdate.mockResolvedValue({
      success: true,
      data: { attemptId, status: "pending", updatedTo: target },
    });
    rpc.updateStatus.mockResolvedValue(status());

    await startUpdate();

    await waitFor(() =>
      expect(rpc.updateStatus).toHaveBeenCalledWith(
        expect.objectContaining({ input: { attemptId } }),
      ),
    );

    expect(document.querySelector("#update-reload-button")).toBeNull();
    expect(document.querySelector("#update-restarting")).not.toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toMatchObject({
      attemptId,
      target,
    });

    vi.unstubAllGlobals();
  });

  it("shows the helper's rollback failure and permits a retry", async () => {
    rpc.applyUpdate.mockResolvedValue({
      success: true,
      data: { attemptId, status: "pending", updatedTo: target },
    });
    rpc.updateStatus
      .mockResolvedValueOnce(status())
      .mockResolvedValue(
        status({
          status: "failed",
          message: "health check failed; rolled back to v0.25.11",
          rolledBack: true,
          completedAt: new Date().toISOString(),
        }),
      );

    await startUpdate();
    await waitFor(() => expect(rpc.updateStatus).toHaveBeenCalledTimes(1));

    act(() => socket.reconnect());

    await waitFor(() =>
      expect(document.body.textContent).toContain(
        "health check failed; rolled back to v0.25.11",
      ),
    );
    expect(localStorage.getItem(storageKey)).toBeNull();
    expect(document.querySelector("#update-now-button")).not.toBeNull();
  });

  it("does not delete a newer tab's stored attempt when this attempt fails", async () => {
    rpc.applyUpdate.mockResolvedValue({
      success: true,
      data: { attemptId, status: "pending", updatedTo: target },
    });
    rpc.updateStatus
      .mockResolvedValueOnce(status())
      .mockResolvedValue(
        status({
          status: "failed",
          message: "this tab's helper failed",
          rolledBack: false,
          completedAt: new Date().toISOString(),
        }),
      );

    await startUpdate();
    await waitFor(() => expect(rpc.updateStatus).toHaveBeenCalledTimes(1));

    const newerTabAttempt = {
      attemptId: otherAttemptId,
      target,
      requestedAt: new Date().toISOString(),
    };
    localStorage.setItem(storageKey, JSON.stringify(newerTabAttempt));
    act(() => socket.reconnect());

    await waitFor(() => expect(document.body.textContent).toContain("this tab's helper failed"));
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toEqual(newerTabAttempt);
  });

  it("does not delete a newer tab's attempt after a mismatched apply response", async () => {
    let settleApply: ((result: unknown) => void) | undefined;
    rpc.applyUpdate.mockImplementation(
      () => new Promise((resolve) => {
        settleApply = resolve;
      }),
    );
    rpc.updateStatus.mockResolvedValue(status());

    await startUpdate();
    await waitFor(() => expect(rpc.applyUpdate).toHaveBeenCalledTimes(1));

    const newerTabAttempt = {
      attemptId: otherAttemptId,
      target,
      requestedAt: new Date().toISOString(),
    };
    localStorage.setItem(storageKey, JSON.stringify(newerTabAttempt));

    await act(async () => {
      settleApply?.({
        success: true,
        data: { attemptId: otherAttemptId, status: "pending", updatedTo: target },
      });
      await Promise.resolve();
    });

    await waitFor(() => expect(document.querySelector("#update-now-button")).not.toBeNull());
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toEqual(newerTabAttempt);
  });

  it.each([
    ["matching", { attemptId, status: "pending", updatedTo: target }],
    ["mismatched", { attemptId: "11111111-1111-4111-8111-111111111111", status: "pending", updatedTo: target }],
  ])("ignores attempt A's late %s apply response after attempt B starts", async (_label, lateData) => {
    let settleAttemptA: ((result: unknown) => void) | undefined;
    rpc.applyUpdate.mockImplementation(({ input }: { input: { attemptId: string } }) => {
      if (input.attemptId === attemptId) {
        return new Promise((resolve) => {
          settleAttemptA = resolve;
        });
      }
      return new Promise(() => undefined);
    });
    rpc.updateStatus.mockImplementation(({ input }: { input: { attemptId: string } }) =>
      input.attemptId === attemptId
        ? Promise.resolve(
            status({
              status: "failed",
              message: "attempt A failed",
              rolledBack: false,
              completedAt: new Date().toISOString(),
            }),
          )
        : new Promise(() => undefined),
    );

    await startUpdate();
    await waitFor(() => expect(document.body.textContent).toContain("attempt A failed"));
    await waitFor(() => expect(document.querySelector("#update-now-button")).not.toBeNull());

    vi.mocked(globalThis.crypto.randomUUID).mockReturnValue(
      otherAttemptId as ReturnType<Crypto["randomUUID"]>,
    );
    fireEvent.click(document.querySelector("#update-now-button")!);
    await waitFor(() =>
      expect(rpc.applyUpdate).toHaveBeenCalledWith(
        expect.objectContaining({ input: { attemptId: otherAttemptId, expectedTarget: target } }),
      ),
    );

    await act(async () => {
      settleAttemptA?.({ success: true, data: lateData });
      await Promise.resolve();
    });

    expect(document.querySelector("#update-now-button")).toBeNull();
    expect(document.querySelector("#update-restarting")).toBeNull();
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toMatchObject({
      attemptId: otherAttemptId,
      target,
    });
  });

  it("offers reload only after the authoritative helper success", async () => {
    rpc.applyUpdate.mockResolvedValue({
      success: true,
      data: { attemptId, status: "pending", updatedTo: target },
    });
    rpc.updateStatus
      .mockResolvedValueOnce(status())
      .mockResolvedValue(
        status({
          status: "succeeded",
          message: "updated to v0.25.12",
          rolledBack: false,
          completedAt: new Date().toISOString(),
        }),
      );

    await startUpdate();
    await waitFor(() => expect(rpc.updateStatus).toHaveBeenCalledTimes(1));

    act(() => socket.reconnect());

    await waitFor(() => expect(document.querySelector("#update-reload-button")).not.toBeNull());
    expect(document.querySelector("#update-restarting")).toBeNull();

    const settledCalls = rpc.updateStatus.mock.calls.length;
    await act(async () => {
      socket.reconnect();
      await new Promise((resolve) => window.setTimeout(resolve, 0));
    });
    expect(rpc.updateStatus).toHaveBeenCalledTimes(settledCalls);
  });

  it("reload keeps a newer tab's stored attempt", async () => {
    const reload = vi.fn();
    vi.stubGlobal("location", { reload });
    rpc.applyUpdate.mockResolvedValue({
      success: true,
      data: { attemptId, status: "pending", updatedTo: target },
    });
    rpc.updateStatus
      .mockResolvedValueOnce(status())
      .mockResolvedValue(
        status({
          status: "succeeded",
          message: "updated to v0.25.12",
          rolledBack: false,
          completedAt: new Date().toISOString(),
        }),
      );

    await startUpdate();
    await waitFor(() => expect(rpc.updateStatus).toHaveBeenCalledTimes(1));
    act(() => socket.reconnect());
    await waitFor(() => expect(document.querySelector("#update-reload-button")).not.toBeNull());

    const newerTabAttempt = {
      attemptId: otherAttemptId,
      target,
      requestedAt: new Date().toISOString(),
    };
    localStorage.setItem(storageKey, JSON.stringify(newerTabAttempt));
    fireEvent.click(document.querySelector("#update-reload-button")!);

    expect(reload).toHaveBeenCalledOnce();
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toEqual(newerTabAttempt);
  });

  it("resumes the same stored attempt on mount and reconnect without rechecking GitHub", async () => {
    localStorage.setItem(
      storageKey,
      JSON.stringify({ attemptId, target, requestedAt: new Date().toISOString() }),
    );
    rpc.updateStatus.mockResolvedValue(status());

    renderCheck();

    await waitFor(() => expect(rpc.updateStatus).toHaveBeenCalledTimes(1));
    expect(rpc.updateStatus).toHaveBeenLastCalledWith(
      expect.objectContaining({ input: { attemptId } }),
    );

    act(() => socket.reconnect());

    await waitFor(() => expect(rpc.updateStatus).toHaveBeenCalledTimes(2));
    expect(rpc.checkUpdate).toHaveBeenCalledTimes(1);
  });

  it("deletes legacy id-less stored attempts without querying global status", async () => {
    localStorage.setItem(
      storageKey,
      JSON.stringify({ target, requestedAt: new Date().toISOString() }),
    );

    renderCheck();

    await waitFor(() => expect(rpc.checkUpdate).toHaveBeenCalledTimes(1));
    expect(localStorage.getItem(storageKey)).toBeNull();
    expect(rpc.updateStatus).not.toHaveBeenCalled();
  });

  it("expires a stored pending attempt instead of polling it forever", async () => {
    localStorage.setItem(
      storageKey,
      JSON.stringify({
        attemptId,
        target,
        requestedAt: new Date(Date.now() - 16 * 60 * 1_000).toISOString(),
      }),
    );
    rpc.updateStatus.mockResolvedValue(status());

    renderCheck();

    await waitFor(() => expect(rpc.checkUpdate).toHaveBeenCalledTimes(1));
    expect(rpc.updateStatus).not.toHaveBeenCalled();
    expect(localStorage.getItem(storageKey)).toBeNull();
    expect(document.querySelector("#update-restarting")).toBeNull();
  });

  it("keeps polling the client attempt id when the apply response is lost", async () => {
    rpc.applyUpdate.mockRejectedValue(new Error("Failed to fetch"));
    rpc.updateStatus.mockResolvedValue(
      status({
        status: "succeeded",
        message: "updated to v0.25.12",
        rolledBack: false,
        completedAt: new Date().toISOString(),
      }),
    );

    await startUpdate();

    await waitFor(() =>
      expect(rpc.updateStatus).toHaveBeenCalledWith(
        expect.objectContaining({ input: { attemptId } }),
      ),
    );
    await waitFor(() => expect(document.querySelector("#update-reload-button")).not.toBeNull());
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toMatchObject({
      attemptId,
      target,
    });
  });

  it("reports an apply failure when its attempt stays unknown past the grace period", async () => {
    vi.useFakeTimers();
    rpc.checkUpdate.mockResolvedValue(updateInfo());
    rpc.applyUpdate.mockRejectedValue(new Error("update request was rejected"));
    rpc.updateStatus.mockResolvedValue(status({ status: "unknown", target: null }));

    renderCheck();
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });
    fireEvent.click(document.querySelector("#update-now-button")!);
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(rpc.updateStatus).toHaveBeenCalledWith(
      expect.objectContaining({ input: { attemptId } }),
    );
    expect(document.querySelector("#update-restarting")).not.toBeNull();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_001);
    });

    expect(document.body.textContent).toContain("update request was rejected");
    expect(document.querySelector("#update-restarting")).toBeNull();
    expect(localStorage.getItem(storageKey)).toBeNull();

    const settledCalls = rpc.updateStatus.mock.calls.length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });
    expect(rpc.updateStatus).toHaveBeenCalledTimes(settledCalls);
  });

  it("never adopts a different attempt after an apply failure", async () => {
    rpc.applyUpdate.mockRejectedValue(new Error("request failed"));
    rpc.updateStatus.mockResolvedValue(
      status({
        attemptId: otherAttemptId,
        status: "succeeded",
        completedAt: new Date().toISOString(),
      }),
    );

    await startUpdate();

    await waitFor(() => expect(rpc.updateStatus).toHaveBeenCalled());
    expect(document.querySelector("#update-reload-button")).toBeNull();
    expect(JSON.parse(localStorage.getItem(storageKey) ?? "null")).toMatchObject({
      attemptId,
      target,
    });
    expect(rpc.updateStatus).toHaveBeenCalledWith(
      expect.objectContaining({ input: { attemptId } }),
    );
  });

  it("times out a stuck status RPC and retries the same attempt", async () => {
    vi.useFakeTimers();
    localStorage.setItem(
      storageKey,
      JSON.stringify({ attemptId, target, requestedAt: new Date().toISOString() }),
    );
    rpc.updateStatus.mockImplementation(() => new Promise(() => undefined));

    renderCheck();
    await act(async () => {
      await Promise.resolve();
    });

    expect(rpc.updateStatus).toHaveBeenCalledTimes(1);
    expect(rpc.updateStatus).toHaveBeenLastCalledWith(
      expect.objectContaining({ input: { attemptId } }),
    );

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_001);
    });

    expect(rpc.updateStatus.mock.calls.length).toBeGreaterThanOrEqual(2);
    for (const [request] of rpc.updateStatus.mock.calls) {
      expect(request).toEqual(expect.objectContaining({ input: { attemptId } }));
    }
  });

  it("stops its interval after the attempt settles", async () => {
    vi.useFakeTimers();
    localStorage.setItem(
      storageKey,
      JSON.stringify({ attemptId, target, requestedAt: new Date().toISOString() }),
    );
    rpc.updateStatus.mockResolvedValue(
      status({
        status: "succeeded",
        message: "updated to v0.25.12",
        rolledBack: false,
        completedAt: new Date().toISOString(),
      }),
    );

    renderCheck();
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(document.querySelector("#update-reload-button")).not.toBeNull();
    expect(rpc.updateStatus).toHaveBeenCalledTimes(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });
    expect(rpc.updateStatus).toHaveBeenCalledTimes(1);
  });

  it("stops its interval after the attempt fails", async () => {
    vi.useFakeTimers();
    localStorage.setItem(
      storageKey,
      JSON.stringify({ attemptId, target, requestedAt: new Date().toISOString() }),
    );
    rpc.updateStatus.mockResolvedValue(
      status({
        status: "failed",
        message: "update helper failed",
        rolledBack: false,
        completedAt: new Date().toISOString(),
      }),
    );

    renderCheck();
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(document.body.textContent).toContain("update helper failed");
    expect(localStorage.getItem(storageKey)).toBeNull();
    expect(rpc.updateStatus).toHaveBeenCalledTimes(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });
    expect(rpc.updateStatus).toHaveBeenCalledTimes(1);
  });
});
