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

  // ⌥⌘R / Ctrl+Alt+R —— R 取 rename，Alt 让它避开浏览器（mod+shift+r 是硬
  // 刷新）；F2 虽是桌面惯例，但 Mac 上要按 fn+F2，故不作默认（仍可改绑）。
  // 焦点在终端里也照样生效（处理器 stopPropagation，不会透给 shell）。
  // 两条路径（快捷键提交、
  // 双击取消）共用同一个会话——建会话是 e2e 里最贵的一步。
  test("⌥⌘R/Ctrl+Alt+R 与双击都能就地重命名：回车提交并落库，Esc 取消不改名", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await h.selectSession(page, id); // 焦点落在终端上——最常见的场景
      const row = h.sessionEntry(page, id);
      await expect(row).toBeVisible();

      const input = page.locator(`[data-rename-session="${id}"]`);
      await expect(input).toHaveCount(0);

      await page.keyboard.press("Control+Alt+R");
      await expect(input).toBeFocused();

      await input.fill("renamed-by-f2");
      await input.press("Enter");
      await expect(input).toHaveCount(0);
      await expect(row).toContainText("renamed-by-f2");
      // 焦点交还终端，而不是掉到 <body> 上（否则接着敲字哪儿都进不去）。
      await expect
        .poll(() =>
          page.evaluate(
            () => document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
          ),
        )
        .toBe(true);

      // 已落库：刷新后（等价于另一台设备打开）名字还在。
      await page.reload();
      await expect(page.locator("#new-session-button")).toBeVisible();
      await expect(h.sessionEntry(page, id)).toContainText("renamed-by-f2");

      // 双击进入编辑，Esc 取消——名字不动。
      const label = h.sessionEntry(page, id).locator("div.font-mono.text-sm").first();
      await label.dblclick();
      await expect(input).toBeFocused();
      await input.fill("throwaway");
      await input.press("Escape");
      await expect(input).toHaveCount(0);
      await expect(h.sessionEntry(page, id)).toContainText("renamed-by-f2");
      await expect(h.sessionEntry(page, id)).not.toContainText("throwaway");
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
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
