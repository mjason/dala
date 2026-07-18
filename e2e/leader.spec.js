// Spacemacs 式 leader 键（mac ⌥Space / 其他 Ctrl+Shift+Space）：which-key 面板 → 单键导航执行。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const h = require("./helpers");

test.describe("Given 一个打开 dala 的用户", () => {
  let cwd, sessionId;

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-leader-`);
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("leader 键打开面板，p→e 切换文件抽屉，Esc 关闭", async ({ page }) => {
    const drawerVisible = () => page.locator("#file-tree").isVisible();
    const before = await drawerVisible();

    await page.keyboard.press("Control+Shift+Space");
    await expect(page.locator("#leader-menu")).toBeVisible();

    // p 进入「面板」层级，e 执行文件抽屉切换，面板随之关闭。
    await page.keyboard.press("p");
    await expect(page.locator('[data-leader-key="e"]')).toBeVisible();
    await page.keyboard.press("e");
    await expect(page.locator("#leader-menu")).toHaveCount(0);
    await expect.poll(drawerVisible).toBe(!before);

    // 再开一次用 Esc 关闭：什么都不执行。
    await page.keyboard.press("Control+Shift+Space");
    await expect(page.locator("#leader-menu")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.locator("#leader-menu")).toHaveCount(0);
    await expect.poll(drawerVisible).toBe(!before);
  });

  test("s→r 重命名：面板关闭后改名输入框保持焦点可用", async ({ page }) => {
    await page.keyboard.press("Control+Shift+Space");
    await expect(page.locator("#leader-menu")).toBeVisible();
    await page.keyboard.press("s");
    await page.keyboard.press("r");
    const input = page.locator(`[data-rename-session="${sessionId}"]`);
    await expect(input).toBeVisible();
    // 焦点必须在输入框里（回归：面板曾把焦点还给终端导致 blur 秒关）。
    await expect(input).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(input).toHaveCount(0);
  });

  test("s→s 会话切换器：列出会话、单键跳转", async ({ page }) => {
    const cwd2 = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-swtgt-`);
    const id2 = await h.createSession(page, cwd2);
    try {
      // 保持第一个会话为当前会话，再用切换器跳到第二个。
      await h.selectSession(page, sessionId);

      await page.keyboard.press("Control+Shift+Space");
      await page.keyboard.press("s");
      await page.keyboard.press("s");
      const picker = page.locator("#leader-session-picker");
      await expect(picker).toBeVisible();

      // 两个会话都在列表里；按目标会话行上的键帽跳转。
      const name2 = require("node:path").basename(cwd2);
      const row = picker.locator("button[data-session-key]", { hasText: name2 });
      await expect(row).toBeVisible();
      const key = await row.getAttribute("data-session-key");
      await page.keyboard.press(key);

      // 面板关闭，第二个会话的终端面板变为可见（active pane）。
      await expect(page.locator("#leader-menu")).toHaveCount(0);
      await expect(page.locator(`[data-terminal-pane="${id2}"]`)).toBeVisible();
      await expect(page.locator(`[data-terminal-pane="${sessionId}"]`)).toBeHidden();

      // 切换器里 ⌫ 逐级返回：picker → 会话组（回归防护）。
      await page.keyboard.press("Control+Shift+Space");
      await page.keyboard.press("s");
      await page.keyboard.press("s");
      await expect(picker).toBeVisible();
      await page.keyboard.press("Backspace");
      await expect(page.locator('[data-leader-key="n"]')).toBeVisible();
      await page.keyboard.press("Escape");
    } finally {
      await h.deleteSession(page, id2).catch(() => {});
      fs.rmSync(cwd2, { recursive: true, force: true });
    }
  });

  test("终端聚焦时 leader 键一样生效（leader 的意义所在）", async ({ page }) => {
    await page.locator(".xterm").first().click();
    await page.keyboard.press("Control+Shift+Space");
    await expect(page.locator("#leader-menu")).toBeVisible();
    await page.keyboard.press("Escape");
  });
});
