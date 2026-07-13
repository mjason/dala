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

/** 通过 CDP 派发真实触摸事件序列,做 (fromX,fromY)→(toX,toY) 的单指滑动。
 * playwright 的 page.touchscreen 只有 tap,没有 swipe;CDP 的
 * Input.dispatchTouchEvent 会生成浏览器级 TouchEvent(带真实时间戳),
 * 走的就是真机上的同一条事件通路。 */
async function swipe(page, fromX, fromY, toX, toY, steps = 8) {
  const cdp = await page.context().newCDPSession(page);
  try {
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: [{ x: fromX, y: fromY }],
    });
    for (let i = 1; i <= steps; i++) {
      await cdp.send("Input.dispatchTouchEvent", {
        type: "touchMove",
        touchPoints: [
          {
            x: Math.round(fromX + ((toX - fromX) * i) / steps),
            y: Math.round(fromY + ((toY - fromY) * i) / steps),
          },
        ],
      });
    }
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  } finally {
    await cdp.detach().catch(() => {});
  }
}

/** 竖直滑动的便捷封装。 */
async function swipeVertical(page, x, fromY, toY) {
  await swipe(page, x, fromY, x, toY);
}

/** __dalaTerm 调试句柄读 emulator buffer 状态(WebGL 下 DOM 没有文字)。 */
async function bufferState(page) {
  return page.evaluate(() => {
    const buf = window.__dalaTerm?.buffer.active;
    return buf
      ? {
          type: buf.type,
          baseY: buf.baseY,
          viewportY: buf.viewportY,
          topLine: buf.getLine(buf.viewportY)?.translateToString(true).trim() ?? "",
        }
      : null;
  });
}

/** 等 shell 就绪且 xterm 的隐藏 textarea 拿到焦点,之后才能用 keyboard 输入。 */
async function waitTerminalReady(page) {
  await expect
    .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 15_000 })
    .toBeGreaterThan(0);
  await expect
    .poll(
      () =>
        page.evaluate(
          () =>
            document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
        ),
      { timeout: 10_000 },
    )
    .toBe(true);
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

      // 桌面端点工具栏"适配宽度"(宽视口下直接可见,不在 ⋯ 菜单里):
      // follower 状态下 Refit = "适配到我的屏幕" = 接管尺寸。
      await desktopPage.locator("#terminal-refit-button").click();
      // 桌面重新成为所有者:横幅消失,布局宽度涨回桌面容器宽度,无缩放。
      await expect(desktopPage.locator("#size-follower-banner")).toHaveCount(0);
      await expect
        .poll(async () => (await screenWidths(desktopPage)).layout, { timeout: 10_000 })
        .toBeGreaterThan(phone.viewport.width);
      const reclaimed = await screenWidths(desktopPage);
      expect(Math.abs(reclaimed.visual - reclaimed.layout)).toBeLessThanOrEqual(2);
      // 手机被降级回 follower:横幅重新出现。
      await expect(phonePage.locator("#size-follower-banner")).toBeVisible({
        timeout: 10_000,
      });
    } finally {
      if (id) await h.deleteSession(desktopPage, id).catch(() => {});
      await phoneCtx?.close();
      await desktop.close();
    }
  });

  test("尺寸所有权乒乓(手机接管→冻结→桌面夺回)不杀前台进程,且夺回后到达全新重绘", async ({ browser }) => {
    const { execSync } = require("child_process");
    const fs = require("fs");
    const desktop = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const desktopPage = await desktop.newPage();
    const tag = `${Date.now()}`;
    const markerFile = `/tmp/dala-e2e-fg-dead-${tag}`;
    const sleepArg = `76543${tag.slice(-3)}`;
    let phoneCtx;
    let id;
    try {
      // 桌面端创建会话并成为尺寸所有者。
      await h.gotoApp(desktopPage);
      id = await h.createSession(desktopPage);
      await expect(desktopPage.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(desktopPage);

      // 前台进程:被 HUP/TERM 打死会留下标记文件;正常存活则一直 sleep。
      // 先 echo 一个标记文本进回滚区,夺回后靠重绘快照把它带回屏幕。
      await desktopPage.keyboard.type(
        `echo REPAINT-${tag}; trap 'echo dead > ${markerFile}' HUP TERM; sleep ${sleepArg}`,
      );
      await desktopPage.keyboard.press("Enter");
      await expect
        .poll(
          () => execSync(`pgrep -fc "slee[p] ${sleepArg}" || true`).toString().trim(),
          { timeout: 10_000 },
        )
        .not.toBe("0");

      // 手机加入并点横幅接管:PTY 重排为手机宽度,前台进程收到 SIGWINCH。
      phoneCtx = await browser.newContext({ ...phone });
      const phonePage = await phoneCtx.newPage();
      await h.gotoApp(phonePage);
      await expect(phonePage.locator(".xterm").first()).toBeVisible();
      await expect(phonePage.locator("#size-follower-banner")).toBeVisible();
      await phonePage.locator("#claim-size-button").click();
      await expect(phonePage.locator("#size-follower-banner")).toHaveCount(0);
      await expect(desktopPage.locator("#size-follower-banner")).toBeVisible({
        timeout: 10_000,
      });

      // 冻结手机页面(近似 Safari 退到后台:JS 停摆,socket 不动)。
      const cdp = await phonePage.context().newCDPSession(phonePage);
      await cdp.send("Page.setWebLifecycleState", { state: "frozen" });

      // 桌面点"适配宽度"夺回:follower 状态下 Refit = claim_size 接管。
      const resetsBefore = await desktopPage.evaluate(
        () => window.__dalaFlow?.resets ?? 0,
      );
      await desktopPage.locator("#terminal-refit-button").click();
      await expect(desktopPage.locator("#size-follower-banner")).toHaveCount(0);

      // 接管后必须收到一份全新重绘快照(reset replay)……
      await expect
        .poll(() => desktopPage.evaluate(() => window.__dalaFlow?.resets ?? 0), {
          timeout: 10_000,
        })
        .toBeGreaterThan(resetsBefore);
      // ……并且快照把回滚区的标记文本带回了桌面的缓冲区。
      await expect
        .poll(
          () =>
            desktopPage.evaluate(() => {
              const buf = window.__dalaTerm?.buffer.active;
              if (!buf) return "";
              let text = "";
              for (let i = 0; i < buf.length; i++) {
                text += (buf.getLine(i)?.translateToString(true) ?? "") + "\n";
              }
              return text;
            }),
          { timeout: 10_000 },
        )
        .toContain(`REPAINT-${tag}`);

      // 整场乒乓后前台进程必须还活着:没有死亡标记,sleep 仍在。
      expect(fs.existsSync(markerFile)).toBe(false);
      expect(
        execSync(`pgrep -fc "slee[p] ${sleepArg}" || true`).toString().trim(),
      ).not.toBe("0");

      // 手机解冻后处理积压的广播,自动降级回 follower(横幅重现)。
      await cdp.send("Page.setWebLifecycleState", { state: "active" });
      await expect(phonePage.locator("#size-follower-banner")).toBeVisible({
        timeout: 10_000,
      });
    } finally {
      try {
        execSync(`pkill -f 'sleep ${sleepArg}' || true`);
      } catch {}
      try {
        fs.rmSync(markerFile, { force: true });
      } catch {}
      if (id) await h.deleteSession(desktopPage, id).catch(() => {});
      await phoneCtx?.close();
      await desktop.close();
    }
  });

  test("390px 视口下工具栏没有够不着的按钮,溢出操作收进 ⋯ 菜单", async ({ browser }) => {
    const context = await browser.newContext({ ...phone });
    const page = await context.newPage();
    let id;
    try {
      await h.gotoApp(page);
      id = await h.createSession(page);
      await expect(page.locator(".xterm").first()).toBeVisible();

      // 页面绝不允许横向滚动。
      const overflowX = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );
      expect(overflowX).toBeLessThanOrEqual(0);

      // 每个可见工具栏按钮的右缘都必须落在视口内(隐藏的按钮已收进溢出菜单)。
      const boxes = await page
        .locator("header button:visible")
        .evaluateAll((els) =>
          els.map((el) => ({ id: el.id, right: el.getBoundingClientRect().right })),
        );
      expect(boxes.length).toBeGreaterThan(0);
      for (const box of boxes) {
        expect(box.right, `按钮 #${box.id} 超出 390px 视口`).toBeLessThanOrEqual(
          phone.viewport.width + 1,
        );
      }

      // 触屏密度:每个可见工具栏按钮的点按高度 ≥ 40px(Apple HIG 量级)。
      const heights = await page
        .locator("header button:visible")
        .evaluateAll((els) =>
          els.map((el) => ({ id: el.id, height: el.getBoundingClientRect().height })),
        );
      for (const box of heights) {
        expect(box.height, `按钮 #${box.id} 点按高度不足`).toBeGreaterThanOrEqual(40);
      }

      // 键盘向操作(Refit / Reset / Detach / 设置)在 ⋯ 菜单里仍可达。
      await page.locator("#toolbar-overflow-button").tap();
      await expect(page.locator("#toolbar-overflow")).toBeVisible();
      await expect(page.locator("#overflow-refit")).toBeVisible();
      await expect(page.locator("#overflow-settings")).toBeVisible();
      await page.locator("#overflow-refit").tap();
      await expect(page.locator("#toolbar-overflow")).toHaveCount(0);
      await expect(page.locator(".xterm").first()).toBeVisible();
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
      await context.close();
    }
  });

  test("触摸键条在手机上可见;点 Esc 不弄崩终端、不抢焦点", async ({ browser }) => {
    const context = await browser.newContext({ ...phone });
    const page = await context.newPage();
    let id;
    try {
      await h.gotoApp(page);
      id = await h.createSession(page);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await expect(page.locator("#touch-key-bar")).toBeVisible();
      // 触摸端的 composer 提示条给的是可点按钮,而不是快捷键徽章。
      await expect(page.locator("#composer-open-touch")).toBeVisible();

      // 触屏密度:键条按钮点按高度 ≥ 40px。
      const escBox = await page.locator('#touch-key-bar [data-key="esc"]').boundingBox();
      expect(escBox.height).toBeGreaterThanOrEqual(40);

      // 等 shell 就绪、终端已拿到焦点(xterm 的隐藏 textarea)。
      await expect
        .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 15_000 })
        .toBeGreaterThan(0);
      const terminalFocused = () =>
        page.evaluate(
          () =>
            document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
        );
      await expect.poll(terminalFocused, { timeout: 10_000 }).toBe(true);

      // 点 Esc:终端不崩、键条还在、焦点仍留在终端(软键盘不会收起)。
      await page.locator('#touch-key-bar [data-key="esc"]').tap();
      await expect(page.locator(".xterm").first()).toBeVisible();
      await expect(page.locator("#touch-key-bar")).toBeVisible();
      expect(await terminalFocused()).toBe(true);

      // Ctrl 粘滞:点一下进入 latched 状态,再点方向键后自动松开。
      const ctrl = page.locator('#touch-key-bar [data-key="ctrl"]');
      await ctrl.tap();
      await expect(ctrl).toHaveAttribute("aria-pressed", "true");
      await page.locator('#touch-key-bar [data-key="right"]').tap();
      await expect(ctrl).toHaveAttribute("aria-pressed", "false");
      expect(await terminalFocused()).toBe(true);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
      await context.close();
    }
  });

  test("触屏可以滑动回滚终端输出", async ({ browser }) => {
    const context = await browser.newContext({ ...phone });
    const page = await context.newPage();
    let id;
    try {
      await h.gotoApp(page);
      id = await h.createSession(page);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);

      // 造 200 行回滚(直接敲进终端,和真机路径一致)。
      await page.keyboard.type("seq 1 200");
      await page.keyboard.press("Enter");
      await expect
        .poll(async () => (await bufferState(page))?.baseY ?? 0, { timeout: 15_000 })
        .toBeGreaterThan(100);

      // 输出完时视口贴底(viewportY == baseY)。
      const before = await bufferState(page);
      expect(before.viewportY).toBe(before.baseY);

      // 手指向下滑 = 往回看历史:viewportY 必须变小。
      await swipeVertical(page, 195, 200, 420);
      await expect
        .poll(async () => (await bufferState(page)).viewportY, { timeout: 5_000 })
        .toBeLessThan(before.baseY);

      // 手指向上滑 = 回到新输出方向:viewportY 回升。
      const mid = await bufferState(page);
      await swipeVertical(page, 195, 420, 200);
      await expect
        .poll(async () => (await bufferState(page)).viewportY, { timeout: 5_000 })
        .toBeGreaterThan(mid.viewportY);

      // 等惯性滚动停稳(连续两次采样相同)再测横滑。
      let prevY = -1;
      await expect
        .poll(
          async () => {
            const cur = (await bufferState(page)).viewportY;
            const stable = cur === prevY;
            prevY = cur;
            return stable;
          },
          { timeout: 5_000, intervals: [250] },
        )
        .toBe(true);

      // 横滑绝不能被劫持成滚动:viewportY 原地不动。
      const beforeH = await bufferState(page);
      await swipe(page, 60, 300, 240, 302);
      const afterH = await bufferState(page);
      expect(afterH.viewportY).toBe(beforeH.viewportY);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
      await context.close();
    }
  });

  test("Alt-screen TUI(less)里竖直滑动转换成方向键,内容跟着走", async ({ browser }) => {
    const context = await browser.newContext({ ...phone });
    const page = await context.newPage();
    let id;
    try {
      await h.gotoApp(page);
      id = await h.createSession(page);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);

      // 在 alt buffer 里打开一个肯定超过一屏的文件。
      await page.keyboard.type("seq 1 500 > /tmp/dala-touch-e2e.txt && less /tmp/dala-touch-e2e.txt");
      await page.keyboard.press("Enter");
      await expect
        .poll(async () => (await bufferState(page))?.type, { timeout: 15_000 })
        .toBe("alternate");
      await expect
        .poll(async () => (await bufferState(page)).topLine, { timeout: 10_000 })
        .toBe("1");

      // 手指向上滑 = 内容前进(等价滚轮向下,xterm 转成 ↓ 方向键喂给 less):
      // 首行必须不再是 "1"。
      await swipeVertical(page, 195, 420, 250);
      await expect
        .poll(async () => (await bufferState(page)).topLine, { timeout: 5_000 })
        .not.toBe("1");

      // 手指向下滑 = 内容回退,能滚回文件开头。
      await swipeVertical(page, 195, 200, 480);
      await swipeVertical(page, 195, 200, 480);
      await expect
        .poll(async () => (await bufferState(page)).topLine, { timeout: 5_000 })
        .toBe("1");

      // 退出 less、清理临时文件。
      await page.keyboard.press("q");
      await page.keyboard.type("rm -f /tmp/dala-touch-e2e.txt");
      await page.keyboard.press("Enter");
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
      await context.close();
    }
  });

  test("桌面(精确指针)上下文不渲染触摸键条", async ({ browser }) => {
    const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    let id;
    try {
      await h.gotoApp(page);
      id = await h.createSession(page);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await expect(page.locator("#touch-key-bar")).toHaveCount(0);
      // 桌面工具栏保持原样:Refit 直接可见,没有 ⋯ 溢出按钮。
      await expect(page.locator("#terminal-refit-button")).toBeVisible();
      await expect(page.locator("#toolbar-overflow-button")).toBeHidden();
      // 密度适配只作用于 coarse pointer:桌面按钮保持紧凑(高度 < 40px)。
      const refitBox = await page.locator("#terminal-refit-button").boundingBox();
      expect(refitBox.height).toBeLessThan(40);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
      await context.close();
    }
  });
});
