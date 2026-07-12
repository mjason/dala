/**
 * The one way to call an ash_rpc function from app code.
 *
 * Every call site used to hand-roll the same four steps: build CSRF
 * headers, check `result.success`, dig `errors[0]?.message`, and cast
 * `result.data as unknown as T`. That boilerplate lived at ~30 places and
 * drifted. `call` owns all four; callers get a discriminated union back.
 *
 *   const r = await call<{ path: string }>(setSpeechPrompt, {
 *     input: { dir, prompt },
 *     fields: ["path", "error"],
 *   });
 *   if (!r.ok) return toast(r.error || t("somethingWentWrong"));
 *   use(r.data.path);
 */
import { buildCSRFHeaders } from "../ash_rpc";

export type RpcOutcome<T> = { ok: true; data: T } | { ok: false; error: string };

type RpcResult = {
  success: boolean;
  data?: unknown;
  errors?: { message?: string }[];
};

// A's default must be `any`: supplying T explicitly (the normal way to name
// the row shape) disables inference for A — TypeScript has no partial type
// argument inference — and any stricter default fails contravariance against
// the generated config types (their required `input`/`fields` keys).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function call<T, A extends object = any>(
  fn: (args: A & { headers: Record<string, string> }) => Promise<RpcResult>,
  args: A,
): Promise<RpcOutcome<T>> {
  let result: RpcResult;
  try {
    result = await fn({ ...args, headers: buildCSRFHeaders() });
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
  if (result.success) return { ok: true, data: result.data as T };
  return { ok: false, error: result.errors?.[0]?.message ?? "" };
}
