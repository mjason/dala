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
