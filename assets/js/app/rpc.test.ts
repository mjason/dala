import { describe, expect, it } from "vitest";
import { call } from "./rpc";

describe("call — the single RPC boilerplate owner", () => {
  it("injects CSRF headers into the wrapped call", async () => {
    document.head.innerHTML = '<meta name="csrf-token" content="tok-123">';
    let seen: Record<string, string> | undefined;
    await call(async (args: { headers: Record<string, string> }) => {
      seen = args.headers;
      return { success: true, data: null };
    }, {});
    expect(seen?.["X-CSRF-Token"]).toBe("tok-123");
  });

  it("passes caller args through untouched", async () => {
    let seen: unknown;
    await call(
      async (args: { input: { dir: string }; headers: Record<string, string> }) => {
        seen = args.input;
        return { success: true, data: null };
      },
      { input: { dir: "/tmp/x" } },
    );
    expect(seen).toEqual({ dir: "/tmp/x" });
  });

  it("success unwraps data with the caller's type", async () => {
    const r = await call<{ path: string }>(
      async () => ({ success: true, data: { path: "/a" } }),
      {},
    );
    expect(r).toEqual({ ok: true, data: { path: "/a" } });
  });

  it("failure surfaces the first error message", async () => {
    const r = await call(
      async () => ({ success: false, errors: [{ message: "boom" }, { message: "later" }] }),
      {},
    );
    expect(r).toEqual({ ok: false, error: "boom" });
  });

  it("failure with no errors yields an empty string for the caller's fallback", async () => {
    const r = await call(async () => ({ success: false }), {});
    expect(r).toEqual({ ok: false, error: "" });
  });

  it("a rejected promise becomes ok:false instead of throwing", async () => {
    const r = await call(async () => {
      throw new Error("network down");
    }, {});
    expect(r).toEqual({ ok: false, error: "network down" });
  });
});
