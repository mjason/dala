// PTY 尺寸所有权 — 手机端体验。
//
// 模型:每个会话最多一个"尺寸所有者",只有所有者的 resize 会到达 PTY。
// 1. 手机单独打开会话 → 第一次 resize 自动认领所有权,PTY 按手机宽度渲染
//    (TUI 原生重排,而不是缩放桌面宽度)。
// 2. 桌面端已持有尺寸时手机加入 → 手机是 follower(按所有者尺寸渲染并缩放),
//    显示横幅;点击接管按钮后 PTY 重排为手机宽度,横幅消失。
//
// 终端内容走 WebGL,DOM 里没有文字 —— 内容断言用截图像素检查(顶部行区域
// 不允许全黑)+ __dalaTerm(调试句柄)读 emulator buffer。
const { test, expect, devices } = require("@playwright/test");
const h = require("./helpers");

// iPhone 14: 390×664 CSS 视口,DPR 3,coarse pointer。defaultBrowserType 字段
// 对 chromium 无效,直接展开即可。
const phone = devices["iPhone 14"];

/** 截取页面区域并统计"非终端背景"像素(背景 #0b0c0e)。 */
async function nonBackgroundPixels(page, clip) {
  const shot = await page.screenshot({ clip });
  return page.evaluate(async (b64) => {
    const img = new Image();
    img.src = "data:image/png;base64," + b64;
    await img.decode();
    const c = document.createElement("canvas");
    c.width = img.width;
    c.height = img.height;
    const ctx = c.getContext("2d");
    ctx.drawImage(img, 0, 0);
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    let count = 0;
    for (let i = 0; i < d.length; i += 4) {
      if (
        Math.abs(d[i] - 11) > 12 ||
        Math.abs(d[i + 1] - 12) > 12 ||
        Math.abs(d[i + 2] - 14) > 12
      ) {
        count++;
      }
    }
    return count;
  }, shot.toString("base64"));
}

/** .xterm-screen 的布局宽度(offsetWidth,不受 transform 影响)与视觉宽度。 */
async function screenWidths(page) {
  return page.evaluate(() => {
    const screen = document.querySelector(".xterm-screen");
    return {
      layout: screen ? screen.offsetWidth : 0,
      visual: screen ? screen.getBoundingClientRect().width : 0,
    };
  });
}

test.describe("Given 手机上的 dala 用户", () => {
  test("手机单独打开会话时,自动认领尺寸并按手机宽度渲染出内容", async ({ browser }) => {
    const context = await browser.newContext({ ...phone });
    const page = await context.newPage();
    let id;
    try {
      await h.gotoApp(page);
      id = await h.createSession(page);
      await expect(page.locator(".xterm").first()).toBeVisible();

      // 等 shell 输出到达并被 xterm 解析(prompt 就绪)。
      await expect
        .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 15_000 })
        .toBeGreaterThan(0);

      // 独占会话 = 自己就是所有者:没有 follower 横幅。
      await expect(page.locator("#size-follower-banner")).toHaveCount(0);

      // PTY 按手机宽度渲染:.xterm-screen 不超过容器宽度(绝不是桌面的 667px),
      // 也没有缩放 transform(layout ≈ visual)。
      await expect
        .poll(async () => (await screenWidths(page)).layout, { timeout: 10_000 })
        .toBeLessThanOrEqual(phone.viewport.width);
      const widths = await screenWidths(page);
      expect(Math.abs(widths.visual - widths.layout)).toBeLessThanOrEqual(2);

      // 顶部行区域必须画出内容(prompt + 光标),不能是一片黑。
      await expect
        .poll(
          () => nonBackgroundPixels(page, { x: 0, y: 50, width: 380, height: 60 }),
          { timeout: 10_000 },
        )
        .toBeGreaterThan(30);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
      await context.close();
    }
  });

  test("桌面端持有尺寸时手机加入是 follower;点击接管后重排为手机宽度", async ({ browser }) => {
    const desktop = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const desktopPage = await desktop.newPage();
    let phoneCtx;
    let id;
    try {
      // 桌面端创建会话并成为尺寸所有者(join 后的第一次 resize 认领)。
      await h.gotoApp(desktopPage);
      id = await h.createSession(desktopPage);
      await expect(desktopPage.locator(".xterm").first()).toBeVisible();
      await expect
        .poll(() => desktopPage.evaluate(() => window.__dalaFlow?.acked ?? 0), {
          timeout: 15_000,
        })
        .toBeGreaterThan(0);

      // 手机加入同一会话(唯一会话自动成为 active)。
      phoneCtx = await browser.newContext({ ...phone });
      const phonePage = await phoneCtx.newPage();
      await h.gotoApp(phonePage);
      await expect(phonePage.locator(".xterm").first()).toBeVisible();

      // follower:横幅出现,网格按桌面宽度渲染、缩放后视觉宽度贴合手机屏。
      await expect(phonePage.locator("#size-follower-banner")).toBeVisible();
      await expect
        .poll(async () => (await screenWidths(phonePage)).layout, { timeout: 10_000 })
        .toBeGreaterThan(phone.viewport.width);
      const scaled = await screenWidths(phonePage);
      expect(scaled.visual).toBeLessThanOrEqual(phone.viewport.width + 2);

      // 缩放态也必须有可见内容。
      await expect
        .poll(
          () => nonBackgroundPixels(phonePage, { x: 0, y: 50, width: 380, height: 50 }),
          { timeout: 10_000 },
        )
        .toBeGreaterThan(30);

      // 点击接管:横幅消失,PTY 重排为手机宽度(布局宽度回落到视口内)。
      await phonePage.locator("#claim-size-button").click();
      await expect(phonePage.locator("#size-follower-banner")).toHaveCount(0);
      await expect
        .poll(async () => (await screenWidths(phonePage)).layout, { timeout: 10_000 })
        .toBeLessThanOrEqual(phone.viewport.width);

      // 原所有者被降级为 follower:桌面端出现同样的横幅。
      await expect(desktopPage.locator("#size-follower-banner")).toBeVisible({
        timeout: 10_000,
      });
    } finally {
      if (id) await h.deleteSession(desktopPage, id).catch(() => {});
      await phoneCtx?.close();
      await desktop.close();
    }
  });
});
