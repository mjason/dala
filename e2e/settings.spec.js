// 设置面板 — tab 布局与语音 tab 的项目级转写提示（dala.jsonc）读写。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const h = require("./helpers");

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

  test("设置面板四个 tab 单行并列", async ({ page }) => {
    await h.openSettings(page);
    const tabs = page.locator("[data-settings-tab]");
    await expect(tabs).toHaveCount(4);
    // 一次 evaluate 里同帧测量四个 tab 的 top —— 逐个 boundingBox 会跨越
    // 弹窗入场动画的不同帧，出现 1-2px 的假偏差（已踩过坑）。
    const tops = await page.evaluate(() =>
      Array.from(document.querySelectorAll("[data-settings-tab]")).map(
        (el) => el.getBoundingClientRect().top,
      ),
    );
    expect(tops).toHaveLength(4);
    for (const top of tops) {
      expect(Math.abs(top - tops[0])).toBeLessThanOrEqual(1);
    }
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
