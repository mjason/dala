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

  test("终端聚焦时 leader 键一样生效（leader 的意义所在）", async ({ page }) => {
    await page.locator(".xterm").first().click();
    await page.keyboard.press("Control+Shift+Space");
    await expect(page.locator("#leader-menu")).toBeVisible();
    await page.keyboard.press("Escape");
  });
});
