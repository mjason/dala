// 富文本输入条（composer）— 快捷键三态循环里的“开 → 聚焦”和“关 → 焦点回终端”。
// composer 是 CodeMirror（#composer-editor .cm-content），内容 DOM 可读；
// 终端本体是 WebGL 渲染，焦点落在 xterm 的隐藏 textarea 上。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const h = require("./helpers");

test.describe("Given 一个有活动会话的用户", () => {
  let cwd;
  let sessionId;

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-composer-`);
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("用户按快捷键 Ctrl+Shift+K 打开 composer 并获得焦点", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    // 焦点应落在编辑器内部（CodeMirror 的 contenteditable）。
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);
  });

  test("关闭后焦点回到终端", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);

    // 已打开且已聚焦时，再按一次快捷键 = 关闭并把焦点交还终端。
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toHaveCount(0);
    await expect
      .poll(() =>
        page.evaluate(() =>
          Boolean(document.activeElement?.classList?.contains("xterm-helper-textarea")),
        ),
      )
      .toBe(true);
  });
});
