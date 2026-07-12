// Battle-tested helpers for dala e2e specs.
//
// IMPORTANT — terminal content is NOT in the DOM: the terminal renders via
// xterm's WebGL renderer, so `textContent` of `.xterm` is EMPTY. Assert
// terminal content via screenshots or server-side effects (files written,
// RPC state), never via textContent. The composer, however, is a CodeMirror
// editor (`#composer-editor .cm-content`) and IS DOM-readable.
const { expect } = require("@playwright/test");

/** POST /rpc/run from inside the page (same-origin, cookie + CSRF apply). */
async function rpcRun(page, payload) {
  return page.evaluate(async (body) => {
    const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content");
    const res = await fetch("/rpc/run", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf ?? "" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`/rpc/run HTTP ${res.status}`);
    return res.json();
  }, payload);
}

/** Open the app root and wait until the React shell is up. */
async function gotoApp(page) {
  await page.goto("/");
  await expect(page.locator("#new-session-button")).toBeVisible();
}

/** Create a terminal session via RPC; resolves to its id. */
async function createSession(page, cwd) {
  const result = await rpcRun(page, {
    action: "create_session",
    input: cwd ? { cwd } : {},
    fields: ["id", "cwd"],
  });
  if (!result.success) {
    throw new Error(`create_session failed: ${JSON.stringify(result.errors)}`);
  }
  return result.data.id;
}

/** Delete a session via RPC (cleanup-safe: swallows nothing — callers wrap). */
async function deleteSession(page, id) {
  const result = await rpcRun(page, { action: "delete_session", identity: id });
  if (!result.success) {
    throw new Error(`delete_session failed: ${JSON.stringify(result.errors)}`);
  }
}

/** Sidebar entry (the clickable row) for a session id. */
function sessionEntry(page, id) {
  return page.locator(`#session-list div.group:has(button[data-delete-session="${id}"])`);
}

/** Make a session the active one by clicking its sidebar entry. */
async function selectSession(page, id) {
  await sessionEntry(page, id).click();
  await expect(page.locator(".xterm").first()).toBeVisible();
}

/** Open the settings modal for the active session (header button). */
async function openSettings(page) {
  await page.locator("#session-settings-button").click();
  await expect(page.locator("[data-settings-tab]").first()).toBeVisible();
}

/** Switch the settings modal to a tab: session | appearance | shortcuts | voice. */
async function openSettingsTab(page, key) {
  await page.locator(`[data-settings-tab="${key}"]`).click();
}

module.exports = {
  rpcRun,
  gotoApp,
  createSession,
  deleteSession,
  sessionEntry,
  selectSession,
  openSettings,
  openSettingsTab,
};
