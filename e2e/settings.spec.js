// 设置面板 — tab 布局与语音 tab 的项目级转写提示（dala.jsonc）读写。
const { test, expect, devices } = require("@playwright/test");
const fs = require("node:fs");
const h = require("./helpers");

// iPhone 14：390×664 CSS 视口、DPR 3、coarse pointer + touch。
// 只取上下文选项 —— devices[...] 里的 defaultBrowserType 放进 test.use 会
// 被 playwright 拒绝（“forces a new worker”）。
const iphone = devices["iPhone 14"];
const phone = {
  viewport: iphone.viewport,
  userAgent: iphone.userAgent,
  deviceScaleFactor: iphone.deviceScaleFactor,
  isMobile: iphone.isMobile,
  hasTouch: iphone.hasTouch,
};

const SEED_PROMPT = "初始提示词 e2e-seed";
const SEED_JSONC = `{
  // e2e-comment-keep 这行注释必须在写回后保留
  "speech": {
    "prompt": ${JSON.stringify(SEED_PROMPT)}
  }
}
`;

test.describe("Given 一个带 dala.jsonc 的项目会话，用户打开设置面板", () => {
  let cwd;
  let sessionId;

  test.beforeEach(async ({ page }) => {
    cwd = `/tmp/dala-e2e-voice-${Math.floor(Math.random() * 1e9)}`;
    fs.mkdirSync(cwd, { recursive: true });
    fs.writeFileSync(`${cwd}/dala.jsonc`, SEED_JSONC);
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  // 快捷键 tab 是最长的一页（14 个动作 + TUI 按键指南）。弹窗必须封顶在
  // 视口内、由内容区自己滚动 —— 否则弹窗被撑长、底部的保存按钮被推出屏幕
  // （曾经的回归）。横屏手机（844×390）尤其致命：内容区若还吃 21rem 的
  // 最小高度，弹窗会超过封顶、保存按钮被 overflow-hidden 裁掉且够不着。
  test("最长的 tab 也不会把保存按钮挤出视口：弹窗内容区自己滚动", async ({ page }) => {
    const geometry = () =>
      page.evaluate(() => {
        const modal = document.querySelector("#session-settings");
        const body = document.querySelector("#settings-body");
        const footer = document.querySelector("#save-settings-button").getBoundingClientRect();
        return {
          modalHeight: modal.getBoundingClientRect().height,
          bodyHeight: body.getBoundingClientRect().height,
          footerBottom: footer.bottom,
          viewport: window.innerHeight,
          bodyScrollable: body.scrollHeight > body.clientHeight,
        };
      });

    await page.setViewportSize({ width: 1000, height: 700 });
    await h.openSettings(page);
    await h.openSettingsTab(page, "shortcuts");

    const save = page.locator("#save-settings-button");
    await expect(save).toBeInViewport({ ratio: 1 });

    let geom = await geometry();
    expect(geom.modalHeight).toBeLessThanOrEqual(geom.viewport);
    expect(geom.footerBottom).toBeLessThanOrEqual(geom.viewport);
    expect(geom.bodyScrollable).toBe(true);

    // 指南在滚动区内，滚到底可见。
    const body = page.locator("#settings-body");
    await body.evaluate((el) => el.scrollTo(0, el.scrollHeight));
    await expect(page.locator("#key-guide")).toBeInViewport();
    await expect(save).toBeInViewport({ ratio: 1 });

    // 横屏手机：宽 ≥640（sm 命中）但高只有 390 —— 最小高度必须让位。
    await page.setViewportSize({ width: 844, height: 390 });
    await expect(save).toBeInViewport({ ratio: 1 });
    geom = await geometry();
    expect(geom.modalHeight).toBeLessThanOrEqual(geom.viewport);
    expect(geom.footerBottom).toBeLessThanOrEqual(geom.viewport);
    expect(geom.bodyHeight).toBeLessThan(336); // 21rem 的最小高度没有生效
    expect(geom.bodyScrollable).toBe(true);
  });

  test("桌面：设置面板五个 tab 单行并列", async ({ page }) => {
    // 显式桌面视口：手机上是 2+2+1 三行（见下面的手机用例），这条断言只对
    // sm 及以上成立。
    await page.setViewportSize({ width: 1000, height: 700 });
    await h.openSettings(page);
    const tabs = page.locator("[data-settings-tab]");
    await expect(tabs).toHaveCount(5);
    // 一次 evaluate 里同帧测量五个 tab 的 top —— 逐个 boundingBox 会跨越
    // 弹窗入场动画的不同帧，出现 1-2px 的假偏差（已踩过坑）。
    const rects = await page.evaluate(() =>
      Array.from(document.querySelectorAll("[data-settings-tab]")).map((el) => {
        const r = el.getBoundingClientRect();
        return { top: r.top, left: r.left };
      }),
    );
    expect(rects).toHaveLength(5);
    for (const r of rects) {
      expect(Math.abs(r.top - rects[0].top)).toBeLessThanOrEqual(1);
    }
    // 五个不同的 left —— 真的是并排 5 列，而不是叠在一起。
    expect(new Set(rects.map((r) => Math.round(r.left))).size).toBe(5);
  });

  test("tab 有完整的 ARIA 语义：左右方向键在 tab 间移动焦点与选中，tabpanel 关联到当前 tab", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1000, height: 700 });
    await h.openSettings(page);

    const first = page.locator('[data-settings-tab="session"]');
    const second = page.locator('[data-settings-tab="appearance"]');
    const last = page.locator('[data-settings-tab="mcp"]');
    const panel = page.locator("#settings-body");

    // 只有选中的 tab 在 tab 序列里（roving tabindex）。
    await expect(first).toHaveAttribute("tabindex", "0");
    await expect(second).toHaveAttribute("tabindex", "-1");
    // tabpanel 关联到当前选中的 tab。
    await expect(panel).toHaveAttribute("role", "tabpanel");
    await expect(panel).toHaveAttribute("aria-labelledby", "settings-tab-session");

    // 方向键：右移到下一个 tab —— 焦点与选中同时移动。
    await first.focus();
    await page.keyboard.press("ArrowRight");
    await expect(second).toHaveAttribute("aria-selected", "true");
    await expect(second).toBeFocused();
    await expect(first).toHaveAttribute("aria-selected", "false");
    await expect(panel).toHaveAttribute("aria-labelledby", "settings-tab-appearance");

    // 左移回环到最后一个 tab（MCP）。
    await first.focus();
    await page.keyboard.press("ArrowLeft");
    await expect(last).toHaveAttribute("aria-selected", "true");
    await expect(last).toBeFocused();
    await expect(page.locator("#mcp-enabled-toggle")).toBeVisible();

    // Home/End 跳到首尾。
    await page.keyboard.press("Home");
    await expect(first).toBeFocused();
    await expect(first).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("End");
    await expect(last).toBeFocused();
  });

  test("语音 tab：转写提示从项目 dala.jsonc 读取、编辑失焦后写回磁盘且保留注释", async ({
    page,
  }) => {
    await h.openSettings(page);
    await h.openSettingsTab(page, "voice");

    // 读取：初始值来自项目里的 dala.jsonc
    const input = page.locator("#speech-prompt-input");
    await expect(input).toHaveValue(SEED_PROMPT);

    // 写回：编辑 + 失焦 → 状态出现 ✓，磁盘文件更新且注释保留
    const updated = "更新后的提示词 e2e-updated";
    await input.fill(updated);
    await input.blur();
    await expect(page.locator("#speech-prompt-status")).toHaveText("✓");

    const onDisk = fs.readFileSync(`${cwd}/dala.jsonc`, "utf8");
    expect(onDisk).toContain(updated);
    expect(onDisk).toContain("e2e-comment-keep");
  });

  test("超长转写提示出现“只取末尾”警告", async ({ page }) => {
    await h.openSettings(page);
    await h.openSettingsTab(page, "voice");
    const input = page.locator("#speech-prompt-input");
    await expect(input).toHaveValue(SEED_PROMPT);
    await input.fill("字".repeat(320));
    await expect(page.locator("#speech-prompt-overflow")).toBeVisible();
  });
});

// 手机端：tab 行曾经是 grid-cols-4，390px 上第四个 tab（语音输入）被裁、
// 弹窗被撑出屏幕右边（用户截图）。13px 下量过 10 个语言的标签宽度，最宽的
// 是 ru「Горячие клавиши」120.8px、de「Spracheingabe」97.5px —— 4 列在
// 390px 上每格只有 ~52px 文字空间，任何语言都放不下。所以窄屏走 2×2。
// 这里只测最宽的 de 与默认的 zh-CN，两个视口：390（iPhone 级）与 320
// （我们愿意兜底的最小手机）。
test.describe("Given 手机上打开设置面板的用户", () => {
  test.use({ ...phone });

  let cwd;
  let sessionId;

  test.beforeEach(async ({ page }) => {
    cwd = `/tmp/dala-e2e-mobile-settings-${Math.floor(Math.random() * 1e9)}`;
    fs.mkdirSync(cwd, { recursive: true });
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  /** 窄屏：侧栏收在抽屉里，设置按钮收在 ⋯ 溢出菜单里。 */
  async function openSettingsOnPhone(page) {
    await page.locator("#nav-toggle-button").tap();
    await expect(h.sessionEntry(page, sessionId)).toBeVisible();
    await h.sessionEntry(page, sessionId).tap();
    await expect(page.locator(".xterm").first()).toBeVisible();
    await page.locator("#toolbar-overflow-button").tap();
    await page.locator("#overflow-settings").tap();
    await expect(page.locator("[data-settings-tab]").first()).toBeVisible();
  }

  /** 同一帧里量弹窗与四个 tab 的几何（逐个 boundingBox 会跨入场动画的帧）。 */
  function geometry(page) {
    return page.evaluate(() => {
      const modal = document.querySelector("#session-settings").getBoundingClientRect();
      const tabs = Array.from(document.querySelectorAll("[data-settings-tab]")).map((el) => {
        const r = el.getBoundingClientRect();
        return {
          key: el.getAttribute("data-settings-tab"),
          left: r.left,
          right: r.right,
          top: r.top,
          // 文字有没有在按钮内部被裁掉（overflow 隐藏部分）。
          overflow: el.scrollWidth - el.clientWidth,
        };
      });
      return {
        vw: window.innerWidth,
        modalLeft: modal.left,
        modalRight: modal.right,
        docOverflow: document.documentElement.scrollWidth - window.innerWidth,
        tabs,
      };
    });
  }

  for (const locale of ["zh-CN", "de"]) {
    test(`${locale}：390 与 320 视口下五个 tab 全在屏内、不被裁，弹窗不越界，语音 tab 可点`, async ({
      page,
    }) => {
      await page.addInitScript((loc) => localStorage.setItem("dala:locale", loc), locale);
      await page.reload();
      await openSettingsOnPhone(page);

      for (const width of [390, 320]) {
        await page.setViewportSize({ width, height: 664 });
        const geom = await geometry(page);

        expect(geom.vw).toBe(width);
        // 弹窗整体在视口内（曾经右边被撑出去）。
        expect(geom.modalLeft).toBeGreaterThanOrEqual(-0.5);
        expect(geom.modalRight).toBeLessThanOrEqual(geom.vw + 0.5);
        expect(geom.docOverflow).toBeLessThanOrEqual(0);

        expect(geom.tabs).toHaveLength(5);

        // 窄屏是 grid-cols-2：五个 tab 排成 2+2+1 三行。headless chromium 的
        // CJK 字形比真机（PingFang/SF）窄半个像素 —— 中文在更多列下"刚好不裁"，
        // 真机上就裁了（用户截图）。所以除了裁切断言，这里直接把 2 列的版式钉死：
        // 任何人把窄屏改成 grid-cols-4/5 立刻红。
        const rows = [...new Set(geom.tabs.map((t) => Math.round(t.top)))].sort((a, b) => a - b);
        expect(rows, `${locale}@${width} rows`).toHaveLength(3);
        const rowCounts = rows.map(
          (row) => geom.tabs.filter((t) => Math.round(t.top) === row).length,
        );
        expect(rowCounts, `${locale}@${width} row counts`).toEqual([2, 2, 1]);

        for (const tab of geom.tabs) {
          expect(tab.left, `${locale}@${width} ${tab.key} left`).toBeGreaterThanOrEqual(-0.5);
          expect(tab.right, `${locale}@${width} ${tab.key} right`).toBeLessThanOrEqual(
            geom.vw + 0.5,
          );
          // 标签整段可见：按钮内没有被裁掉的文字。
          expect(tab.overflow, `${locale}@${width} ${tab.key} clipped`).toBeLessThanOrEqual(1);
        }
      }

      // 320px 上依然点得动语音 tab（tap 带命中检测：被遮挡/出屏都会失败）。
      await page.locator('[data-settings-tab="voice"]').tap();
      await expect(page.locator('[data-settings-tab="voice"]')).toHaveAttribute(
        "aria-selected",
        "true",
      );
      await expect(page.locator("#session-name-input")).toHaveCount(0);
      await expect(page.locator("#save-settings-button")).toBeInViewport({ ratio: 1 });
    });
  }
});
