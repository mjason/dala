const fs = require("fs");
const { test, expect } = require("@playwright/test");
const h = require("./helpers");

// The MCP enable-state + token are a global DB singleton toggled from the
// Settings → MCP tab. This exercises the real RPC round-trip end-to-end:
// mcpSettings (load) → setMcpEnabled (toggle) → regenerateMcpToken, and the
// copy-ready client snippets that bake the LIVE token into the Bearer header.
test.describe("Given 一个支持 MCP 的 dala（设置里可开关 MCP、显示令牌）", () => {
  let sessionId;
  let cwd;

  test.beforeEach(async ({ page }) => {
    cwd = `/tmp/dala-e2e-mcp-${Math.floor(Math.random() * 1e9)}`;
    fs.mkdirSync(cwd, { recursive: true });
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    // The test ends with MCP toggled back off; other specs don't touch /mcp, so
    // a leftover-enabled singleton on a mid-test failure is harmless.
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("开关打开→显示端点+真令牌+接入片段；重生成换令牌；关闭即隐藏", async ({ page }) => {
    await h.openSettings(page);
    await h.openSettingsTab(page, "mcp");

    const toggle = page.getByRole("switch"); // the only switch on the MCP tab
    const url = page.locator("#mcp-endpoint-url");
    const tokenEl = page.locator("#mcp-token");
    const claudeBlock = page.locator('[data-mcp-client="claude-code"]');

    // A fresh instance provisions the singleton disabled → connection details
    // hidden. Turn it on (robust to whatever state a prior test left behind).
    if (!(await url.isVisible().catch(() => false))) {
      await toggle.click();
    }
    await expect(toggle).toHaveAttribute("aria-checked", "true");
    await expect(url).toBeVisible();
    await expect(url).toContainText("/mcp");

    // The real token shows, and it is baked into the copy-ready snippet.
    await expect(tokenEl).toBeVisible();
    const token1 = (await tokenEl.innerText()).trim();
    expect(token1.length).toBeGreaterThanOrEqual(20);
    await expect(claudeBlock).toContainText(`Bearer ${token1}`);

    // Regenerate mints a new token; the shown value AND the snippets follow it.
    await page.locator("#mcp-regenerate-token").click();
    await expect(tokenEl).not.toHaveText(token1);
    const token2 = (await tokenEl.innerText()).trim();
    expect(token2).not.toBe(token1);
    await expect(claudeBlock).toContainText(`Bearer ${token2}`);

    // Turning it off hides the endpoint/token/snippets (nothing to connect to).
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-checked", "false");
    await expect(url).toHaveCount(0);
    await expect(tokenEl).toHaveCount(0);
    await expect(claudeBlock).toHaveCount(0);
  });
});
