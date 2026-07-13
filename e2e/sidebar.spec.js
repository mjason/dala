// 侧栏拖拽排序 — 顺序持久化在服务端（position 浮点键），刷新后不变。
// 拖拽从每行专用的 handle（⠿）发起：桌面 hover 才显示，粗指针常显；
// 列表本身不设 touch-action:none，移动端在行上滑动仍是滚动。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const h = require("./helpers");

/** 侧栏当前行顺序（只保留本测试创建的会话，忽略其他 spec 的残留）。 */
async function rowOrder(page, ids) {
  const all = await page.$$eval("#session-list [data-session-row]", (els) =>
    els.map((el) => el.getAttribute("data-session-row")),
  );
  return all.filter((id) => ids.includes(id));
}

test.describe("Given 侧栏里有三个会话", () => {
  let cwd;

  test.beforeEach(() => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-sidebar-`);
  });

  test.afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("用户把第 3 行拖到第 1 行上方，顺序立即生效且刷新后保持", async ({ page }) => {
    await h.gotoApp(page);
    const ids = [];
    try {
      for (let i = 0; i < 3; i++) ids.push(await h.createSession(page, cwd));
      await expect(h.sessionEntry(page, ids[2])).toBeVisible();
      expect(await rowOrder(page, ids)).toEqual(ids);

      // handle 桌面端 hover 才可见（透明但一直占位，可直接按下）。
      await h.sessionEntry(page, ids[2]).hover();
      const handle = await page
        .locator(`[data-drag-session="${ids[2]}"]`)
        .boundingBox();
      const firstRow = await page
        .locator(`[data-session-row="${ids[0]}"]`)
        .boundingBox();

      await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
      await page.mouse.down();
      // 先越过 5px 启动阈值，再落到第 1 行的上半部（中点以上 = 插到它前面）。
      await page.mouse.move(handle.x + handle.width / 2, handle.y - 15, { steps: 4 });
      await page.mouse.move(firstRow.x + 12, firstRow.y + 3, { steps: 8 });
      await page.mouse.up();

      // 乐观更新立即生效……
      await expect.poll(() => rowOrder(page, ids)).toEqual([ids[2], ids[0], ids[1]]);

      // ……并且已持久化：整页刷新后顺序不变（等价于另一台设备打开）。
      await page.reload();
      await expect(page.locator("#new-session-button")).toBeVisible();
      await expect(h.sessionEntry(page, ids[2])).toBeVisible();
      await expect.poll(() => rowOrder(page, ids)).toEqual([ids[2], ids[0], ids[1]]);
    } finally {
      for (const id of ids) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("只有 handle 禁用触摸平移，列表本身仍可滚动", async ({ page }) => {
    // 真实的移动端滚动断言需要一个溢出的长列表（几十个会话），太重且易
    // flaky；退而断言约束本身：touch-action:none 只落在 handle 上，
    // 列表容器与行保持默认（触摸平移 = 滚动）。
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await expect(h.sessionEntry(page, id)).toBeVisible();

      const touchAction = (selector) =>
        page.$eval(selector, (el) => getComputedStyle(el).touchAction);
      expect(await touchAction(`[data-drag-session="${id}"]`)).toBe("none");
      expect(await touchAction("#session-list")).not.toBe("none");
      expect(await touchAction(`[data-session-row="${id}"]`)).not.toBe("none");
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });
});
