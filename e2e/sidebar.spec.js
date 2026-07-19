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
  test("重命名输入框原地无缝替换：行高与文字位置一个像素都不动", async ({ page }) => {
    // 曾经的样子：输入框自带 1px 边框 + 4px 内边距 + inline-block 基线降部
    // → 行高 52→58、文字右移 5px、整行"跳一下"。现在用负边距抵消内边距、
    // ring 描边不占布局、block 消除基线降部，几何完全一致。
    await h.gotoApp(page);
    const sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
    await expect(h.sessionEntry(page, sessionId)).toBeVisible();

    const geom = async () =>
      page.evaluate((id) => {
        const row = document.querySelector(`[data-session-row="${id}"]`);
        const input = row.querySelector("input[data-rename-session]");
        const el = input || row.querySelector(".truncate.font-mono");
        const r = row.getBoundingClientRect();
        const e = el.getBoundingClientRect();
        // 输入框的文字起点要加回它自己的 4px 左内边距
        return {
          rowH: Math.round(r.height),
          textX: Math.round(e.x + (input ? 4 : 0)),
          textY: Math.round(e.y),
        };
      }, sessionId);

    const before = await geom();
    await page.keyboard.press("Control+Alt+R");
    await expect(page.locator(`input[data-rename-session="${sessionId}"]`)).toBeVisible();
    const after = await geom();

    expect(after.rowH).toBe(before.rowH);
    expect(Math.abs(after.textX - before.textX)).toBeLessThanOrEqual(1);
    expect(Math.abs(after.textY - before.textY)).toBeLessThanOrEqual(1);

    await page.keyboard.press("Escape");
    await h.deleteSession(page, sessionId).catch(() => {});
  });

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

  test("重命名后 shell 的状态广播不再把旧名字顶回来（脏 struct 回归）", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await h.selectSession(page, id);
      const row = h.sessionEntry(page, id);
      await expect(row).toBeVisible();

      // 就地重命名并确认已生效。
      await page.keyboard.press("Control+Alt+R");
      const input = page.locator(`[data-rename-session="${id}"]`);
      await expect(input).toBeFocused();
      await input.fill("sticky-name");
      await input.press("Enter");
      await expect(row).toContainText("sticky-name");

      // 让 shell 退出：mark_exited 曾经拿服务端 spawn 时缓存的旧 struct
      // 更新，session_updated 广播带着旧名字/旧位置，把所有侧栏顶回去。
      await page.locator(".xterm").first().click();
      await page.keyboard.type("exit");
      await page.keyboard.press("Enter");

      // 状态点变灰 = exited 的 session_updated 广播已经到达前端。
      await expect(row.locator('span[class*="bg-fg-muted"]').first()).toBeVisible({
        timeout: 15_000,
      });
      // 广播到达之后，名字元素必须还是新名字（行里另有 cwd 列，含默认名，
      // 不能用整行断言）。
      await expect(row.locator("div.font-mono.text-sm").first()).toHaveText("sticky-name");
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("用户实锤复现：重命名后一 cd 目录，名字立刻变回默认——cwd 轮询广播不得回滚名字", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    const cdTarget = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-cdtarget-`);
    try {
      id = await h.createSession(page, cwd);
      await h.selectSession(page, id);
      const row = h.sessionEntry(page, id);
      const nameEl = row.locator("div.font-mono.text-sm").first();

      // 就地重命名。
      await page.keyboard.press("Control+Alt+R");
      const input = page.locator(`[data-rename-session="${id}"]`);
      await expect(input).toBeFocused();
      await input.fill("sticky-cd");
      await input.press("Enter");
      await expect(nameEl).toHaveText("sticky-cd");

      // 用户的复现步骤：在终端里换目录。服务端 2s 一轮的 cwd 轮询会发现并
      // update_cwd —— 曾经拿 spawn 时缓存的旧 struct 更新，session_updated
      // 广播带旧名字，名字当场变回默认。
      await page.locator(".xterm").first().click();
      await page.keyboard.type(`cd ${cdTarget}`);
      await page.keyboard.press("Enter");

      // 行里 cwd 列出现新目录名 = update_cwd 的广播已经到达并被应用。
      const target = require("node:path").basename(cdTarget);
      await expect(row).toContainText(target, { timeout: 15_000 });

      // 广播应用之后，名字必须原地不动。
      await expect(nameEl).toHaveText("sticky-cd");
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
      fs.rmSync(cdTarget, { recursive: true, force: true });
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
