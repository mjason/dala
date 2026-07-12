// 会话生命周期 — 创建与删除都能在侧栏里看到结果。
// 终端内容走 WebGL 渲染，DOM 里读不到文字：这里只断言 .xterm 挂载即“终端就绪”。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const h = require("./helpers");

test.describe("Given 一个打开 dala 的用户", () => {
  let cwd;

  test.beforeEach(() => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-session-`);
  });

  test.afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("用户创建新会话后，会话出现在侧栏且终端就绪", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      // session_created 走 lobby channel 广播，侧栏应实时出现该条目。
      await expect(h.sessionEntry(page, id)).toBeVisible();
      // 唯一会话自动成为 active —— 终端视图挂载即就绪。
      await expect(page.locator(".xterm").first()).toBeVisible();
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("用户删除会话后，会话从侧栏消失", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    try {
      const entry = h.sessionEntry(page, id);
      await expect(entry).toBeVisible();
      // 删除按钮 hover 才显示；点击后弹确认框，再点确认。
      await entry.hover();
      await entry.locator(`button[data-delete-session="${id}"]`).click();
      await page.locator("#confirm-delete-button").click();
      await expect(entry).toHaveCount(0);
    } finally {
      // 兜底清理：正常路径下会话已经删掉，RPC 会失败，忽略即可。
      await h.deleteSession(page, id).catch(() => {});
    }
  });
});
