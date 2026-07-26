// 向上滚加载回滚缓冲时，画面不得被遮罩盖住。
// 曾经的行为：历史快照上限 512KiB、按 192KiB 分批，`!done` 让遮罩一直盖到
// 最后一批解析完 —— 用户看到的是"滑动就黑屏，几秒后自己好"。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const h = require("./helpers");

async function ready(page) {
  await expect
    .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 20_000 })
    .toBeGreaterThan(0);
  await page.evaluate(() => window.__dalaTerm?.focus());
}

const replayState = (page) =>
  page.evaluate(
    () =>
      document
        .querySelector("[data-terminal-pane]:not(.invisible) [data-replay-state]")
        ?.getAttribute("data-replay-state") ??
      document.querySelector("[data-replay-state]")?.getAttribute("data-replay-state"),
  );

test.describe("Given 一个有大量回滚缓冲的会话", () => {
  let cwd;
  let id;

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-scroll-`);
    await page.addInitScript(() => localStorage.setItem("dala:drawer-open", "0"));
    await h.gotoApp(page);
    id = await h.createSession(page, cwd);
    await h.selectSession(page, id);
    await ready(page);
  });

  test.afterEach(async ({ page }) => {
    await h.deleteSession(page, id).catch(() => {});
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("向上滚载入历史时，终端不被遮罩盖住", async ({ page }) => {
    await page.keyboard.type("seq 1 40000");
    await page.keyboard.press("Enter");
    await page.waitForTimeout(5_000);

    // 刷新后客户端只有当前屏，历史是懒加载的 —— 这正是向上滚会去取它的原因。
    await page.reload();
    await h.gotoApp(page);
    await h.selectSession(page, id);
    await ready(page);

    const loaded = () =>
      page.evaluate(() => (window.__dalaTerm?.buffer.active.length ?? 0) > 1_000);
    expect(await loaded()).toBe(false);

    // 轮询会漏掉一闪而过的遮罩，所以用 MutationObserver 记录每一次状态变化。
    await page.evaluate(() => {
      const seen = [];
      window.__coverStates = seen;
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          const value = record.target.getAttribute("data-replay-state");
          if (value) seen.push(value);
        }
      });
      for (const node of document.querySelectorAll("[data-replay-state]")) {
        seen.push(node.getAttribute("data-replay-state") ?? "");
        observer.observe(node, { attributes: true, attributeFilter: ["data-replay-state"] });
      }
    });

    await page.mouse.move(600, 400);
    for (let burst = 0; burst < 10; burst++) {
      for (let i = 0; i < 6; i++) await page.mouse.wheel(0, -240);
      await page.waitForTimeout(150);
    }
    await page.waitForTimeout(2_000);
    const states = await page.evaluate(() => window.__coverStates ?? []);

    // 历史确实加载了（否则这个用例什么都没测到）。
    await expect.poll(loaded, { timeout: 20_000 }).toBe(true);

    expect(
      states.filter((state) => state === "cover"),
      `replay states seen: ${states.join(",")}`,
    ).toHaveLength(0);
  });
});
