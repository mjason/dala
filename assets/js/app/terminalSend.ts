/** How composed text + Enter reach the foreground app's PTY. Ported from
 * Warp's per-agent rich-input strategies (app/src/terminal/view/
 * use_agent_footer): Codex's paste-burst heuristics swallow a rapid Enter
 * (bracketed paste + immediate CR), while Claude/opencode/Gemini ignore a
 * CR that arrives in the same buffer as the text (bare text + delayed CR). */
export type SendStrategy = "inline" | "bracketed" | "delayed" | "bracketed-delayed";

/** The strategy to use when the caller did not pick one. */
export function resolveSendMode(
  strategy: SendStrategy | undefined,
  bracketedPasteMode: boolean,
): SendStrategy {
  return strategy ?? (bracketedPasteMode ? "bracketed" : "inline");
}

/**
 * Deliver composed text (and optionally Enter) through `push` with the
 * given strategy's framing and timing:
 * - bracketed modes wrap the body in ESC[200~ … ESC[201~;
 * - delayed modes send the CR on its own timer (50ms, 300ms when bracketed);
 * - Claude Code's `!` (bash) / `&` (background) mode prefixes go out alone
 *   first (non-bracketed only), so the agent switches modes before the text.
 */
export function sendComposedText(
  text: string,
  submit: boolean,
  mode: SendStrategy,
  push: (data: string) => void,
): void {
  const bracket = mode === "bracketed" || mode === "bracketed-delayed";

  let body = text;
  let delayExtra = 0;
  if ((body.startsWith("!") || body.startsWith("&")) && body.length > 1 && !bracket) {
    push(body[0]);
    body = body.slice(1);
    delayExtra = 50;
  }

  const sendBody = () => {
    if (body) push(bracket ? `\x1b[200~${body}\x1b[201~` : body);
    if (!submit) return;
    if (mode === "delayed" || mode === "bracketed-delayed") {
      window.setTimeout(() => push("\r"), mode === "bracketed-delayed" ? 300 : 50);
    } else {
      push("\r");
    }
  };
  if (delayExtra) window.setTimeout(sendBody, delayExtra);
  else sendBody();
}
