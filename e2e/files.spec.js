// 文件抽屉的实时监控 — 终端命令/agent 在会话目录里建删文件时，抽屉不需要
// 手动刷新就能跟上（服务端 dala_holder watch 递归监视 + 前端就近路由刷新）。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const h = require("./helpers");

test.describe("Given 打开文件抽屉的用户", () => {
  let cwd;

  test.beforeEach(() => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-files-`);
  });

  test.afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("外部建删文件时抽屉自动跟上（含嵌套目录），可见目录 ≤1s", async ({ page }) => {
    fs.writeFileSync(path.join(cwd, "seed.txt"), "seed");
    fs.mkdirSync(path.join(cwd, "nested"));

    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    try {
      await expect(page.locator(".xterm").first()).toBeVisible();
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toBeVisible();
      await expect(page.locator(`[data-path="${cwd}/seed.txt"]`)).toBeVisible();

      // 预热：watch 通道建立与抽屉首次渲染是并行的，反复触碰一个 marker
      // 文件直到它自己出现，证明推送链路已经活了 —— 之后的断言才谈延迟。
      const marker = path.join(cwd, "watch-ready.tmp");
      await expect
        .poll(
          async () => {
            fs.writeFileSync(marker, String(Date.now()));
            return page.locator(`[data-path="${marker}"]`).isVisible();
          },
          { timeout: 15_000, intervals: [300] },
        )
        .toBe(true);

      // 根目录新建 → ≤1s 内出现（Rust 去抖 200ms + 服务端 100ms + 刷新往返）。
      fs.writeFileSync(path.join(cwd, "created-later.txt"), "x");
      await expect(page.locator(`[data-path="${cwd}/created-later.txt"]`)).toBeVisible({
        timeout: 2000,
      });

      // 删除 → 行消失。
      fs.rmSync(path.join(cwd, "created-later.txt"));
      await expect(page.locator(`[data-path="${cwd}/created-later.txt"]`)).toHaveCount(0, {
        timeout: 2000,
      });

      // 展开嵌套目录后，外部往里写 → 同样自动出现（递归监视覆盖全树）。
      await page.click(`[data-path="${cwd}/nested"]`);
      fs.writeFileSync(path.join(cwd, "nested", "inner.txt"), "y");
      await expect(page.locator(`[data-path="${cwd}/nested/inner.txt"]`)).toBeVisible({
        timeout: 2000,
      });
    } finally {
      await h.deleteSession(page, id).catch(() => {});
    }
  });
});
