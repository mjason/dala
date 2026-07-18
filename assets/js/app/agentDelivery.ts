import { splitAgentAttachments } from "./agentAttachments";

/**
 * Delivery planning for composer sends: WHAT to paste into the PTY, in what
 * order, with which paste strategy and pacing. Pure — the App executes the
 * plan (termActions.sendText + waits), tests assert on it directly.
 *
 * Why interleaving exists: agents only attachment-ify a pasted path when the
 * paste IS the path (opencode → File chip, Claude Code → [Image #N]) — mixed
 * into a sentence it degrades to plain text. So each dala-managed attachment
 * path goes out as its own bracketed paste, interleaved with the text runs
 * in their original order: the chips land where the user placed the images.
 */

export type PasteStrategy = "bracketed" | "bracketed-delayed" | "delayed";

export type DeliveryStep = {
  text: string;
  submit: boolean;
  strategy?: PasteStrategy;
  /** Pacing before the next step (agent TUIs need time per paste frame). */
  waitAfterMs?: number;
};

const AGENTS = ["claude", "opencode", "gemini", "codex", "copilot"];

/**
 * The app the delivery should target. Live process sniffing (foreground_app)
 * can miss — mid-task the tty's foreground group may be a spawned tool, a
 * mux pane may report its own command — so the agent identity recorded from
 * OSC 777 events (`composerApp`) backs it up.
 */
export function resolveApp(detected: string, composerApp: string | null): string {
  if (AGENTS.includes(detected)) return detected;
  if (composerApp && AGENTS.includes(composerApp)) return composerApp;
  return detected;
}

function strategyFor(app: string, text: string): PasteStrategy | undefined {
  if (app === "codex") return "bracketed";
  if (app === "copilot") return "bracketed-delayed";
  if (app === "claude" || app === "opencode" || app === "gemini") {
    // Warp sends bare text to these, but a bare multiline paste would
    // submit at the first newline — bracket those.
    return text.includes("\n") ? "bracketed-delayed" : "delayed";
  }
  return undefined;
}

const IMAGE = /\.(png|jpe?g|gif|webp|bmp|svg|tiff?)$/i;

export function planDelivery(app: string, text: string, submit: boolean): DeliveryStep[] {
  const strategy = strategyFor(app, text);
  const segments = splitAgentAttachments(text);
  const paths = segments.filter((s) => s.type === "path");

  // Interleave whenever dala-managed attachment paths are present — even
  // under an unrecognized app: detection failing mid-task is far more likely
  // than the user pasting our tmp paths at a bare prompt, and for a plain
  // shell the interleaved pastes still reproduce the exact same text.
  if (paths.length === 0) return [{ text, submit, strategy }];

  const steps: DeliveryStep[] = segments.map((segment) => {
    if (segment.type === "path") {
      // Text files: Claude Code and Gemini attach @path references inline
      // (content lands in context, no Read round-trip, no permission
      // prompt); opencode/codex read bare paths. Images keep bare paths —
      // that's what all the image-attachment detectors key on.
      const prefix = !IMAGE.test(segment.value) && (app === "claude" || app === "gemini") ? "@" : "";
      return { text: prefix + segment.value + " ", submit: false, strategy: "bracketed", waitAfterMs: 200 };
    }
    // Trailing space keeps the run separated from a following chip.
    const run = segment.value + " ";
    return {
      text: run,
      submit: false,
      strategy: run.includes("\n") ? ("bracketed" as const) : undefined,
      waitAfterMs: 120,
    };
  });

  if (submit) steps.push({ text: "", submit: true, strategy: strategy ?? "delayed" });
  return steps;
}
