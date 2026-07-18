// Renderer and GPU processes can die under memory pressure (OOM, WSL2
// thrash, driver reset). Electron does not reload the page for you: the
// window just turns black until the user restarts the whole client. Reload
// crashed webContents automatically instead — capped, so a page that
// crashes on every boot cannot cause an infinite reload storm.

const RELOAD_WINDOW_MS = 60_000;
const MAX_RELOADS_PER_WINDOW = 3;

// "clean-exit" is a normal teardown (window closing, in-place navigation),
// not a crash.
const BENIGN_REASONS = new Set(["clean-exit"]);

/** Per-webContents reload throttle: at most MAX_RELOADS_PER_WINDOW reloads
 * within any RELOAD_WINDOW_MS span, and never for benign exits. */
function createReloadPolicy(now = () => Date.now()) {
  const history = [];
  return {
    shouldReload(reason) {
      if (BENIGN_REASONS.has(reason)) return false;
      const t = now();
      while (history.length > 0 && t - history[0] > RELOAD_WINDOW_MS) history.shift();
      if (history.length >= MAX_RELOADS_PER_WINDOW) return false;
      history.push(t);
      return true;
    },
  };
}

/** Reload `contents` after an abnormal renderer death. Returns the policy so
 * a GPU-process death (app-level event) can route through the same cap. */
function attachCrashRecovery(contents, { log = console.error, policy = createReloadPolicy() } = {}) {
  contents.on("render-process-gone", (_event, details) => {
    const reason = (details && details.reason) || "unknown";
    if (!policy.shouldReload(reason)) {
      log(`dala: renderer gone (${reason}) — reload cap reached, leaving window as-is`);
      return;
    }
    log(`dala: renderer gone (${reason}) — reloading`);
    contents.reload();
  });
  return policy;
}

/** After an abnormal GPU-process death Chromium restarts the GPU, but
 * compositing for existing windows can stay black. Nudge every live
 * webContents through its own reload policy. */
function recoverFromGpuCrash(contentsWithPolicies, reason, { log = console.error } = {}) {
  for (const { contents, policy } of contentsWithPolicies) {
    if (!contents || contents.isDestroyed?.()) continue;
    if (!policy.shouldReload(reason)) continue;
    log(`dala: GPU process gone (${reason}) — reloading window`);
    contents.reload();
  }
}

module.exports = { createReloadPolicy, attachCrashRecovery, recoverFromGpuCrash, BENIGN_REASONS };
