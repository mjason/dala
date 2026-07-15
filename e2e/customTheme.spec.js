// 自定义主题 —— 编辑器 + 主题库选择器 + 跨设备实时同步 + 亮色微调。
//
// 与 theme.spec 同理：不看像素，只看主题 token 的落地效果。自定义主题在服务端
// 持久化（匿名即“全局库”，实例内共享），所以在 A 设备新建的主题，一台全新的 B
// 设备（独立 context）打开主题库就能看到并选中——外壳(--color-bg0/body 背景)与
// 终端(xterm 调色板真身 window.__dalaTerm.options.theme.background)一起重着色。
//
// 主题行是全实例共享的，用例之间必须清干净（afterEach 里逐个 delete_theme），
// 否则串场（参考 voice.spec 对共享设置行的归零处理）。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const h = require("./helpers");

// theme.spec 里验证过的读取器：证明外壳 + 终端调色板真身一起翻。
const cssVarBg0 = (page) =>
  page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue("--color-bg0").trim(),
  );
const bodyBg = (page) => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
const termThemeBg = (page) =>
  page.evaluate(() => window.__dalaTerm?.options?.theme?.background ?? null);

// 一个自定义主题的两处“可证明”覆盖：外壳 bg0 与终端背景（独立于 bg0）。
const CUSTOM_BG0 = "#123456"; // → rgb(18, 52, 86)
const CUSTOM_BG0_RGB = "rgb(18, 52, 86)";
const CUSTOM_TERM = "#654321";

async function createThemeRpc(page, input) {
  const r = await h.rpcRun(page, {
    action: "create_theme",
    input,
    fields: ["id", "name", "base"],
  });
  if (!r.success) throw new Error(`create_theme failed: ${JSON.stringify(r.errors)}`);
  return r.data;
}

async function listThemesRpc(page) {
  const r = await h.rpcRun(page, {
    action: "list_themes",
    fields: ["id", "name", "ownerId", "builtin", "base"],
  });
  if (!r.success) throw new Error(`list_themes failed: ${JSON.stringify(r.errors)}`);
  return r.data;
}

async function deleteThemeRpc(page, id) {
  await h.rpcRun(page, { action: "delete_theme", identity: id }).catch(() => {});
}

/** Open the settings modal on the appearance tab (mounts the theme library). */
async function openAppearance(page) {
  await h.openSettings(page);
  await h.openSettingsTab(page, "appearance");
  await expect(page.locator("#theme-setting-control")).toBeVisible();
}

test.describe("Given 一个支持自定义主题的 dala 实例", () => {
  let cwd;
  let sessionId;
  let createdIds;

  test.beforeEach(async ({ page }) => {
    cwd = `/tmp/dala-e2e-customtheme-${Math.floor(Math.random() * 1e9)}`;
    fs.mkdirSync(cwd, { recursive: true });
    createdIds = [];
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    for (const id of createdIds) await deleteThemeRpc(page, id);
    createdIds = [];
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("跨设备库 + 外壳终端同时重着色：A 新建主题，B 设备看到并选中后一起重着色", async ({
    page,
    browser,
  }) => {
    const name = `E2E Midnight ${Math.floor(Math.random() * 1e9)}`;

    // 设备 A：在编辑器里新建一个暗色主题，改 bg0（界面组）+ 终端背景（终端基础组）。
    await openAppearance(page);
    await page.locator("#new-theme-button").click();
    await expect(page.locator("#theme-editor")).toBeVisible();
    await page.locator("#theme-name-input").fill(name);
    await page.locator('[data-theme-base="dark"]').click();
    await page.locator("#theme-hex-bg0").fill(CUSTOM_BG0);
    await page.locator("#theme-hex-termBackground").fill(CUSTOM_TERM);
    await page.locator("#save-theme-button").click();
    await expect(page.locator("#theme-editor")).toHaveCount(0);

    // 拿到服务端生成的 id（用于 B 端定位 + 收尾清理）。
    const row = (await listThemesRpc(page)).find((t) => t.name === name);
    expect(row, "created theme should be listed").toBeTruthy();
    createdIds.push(row.id);

    // 设备 B：全新 context（独立 localStorage/cookie），打开主题库应看到该主题。
    const second = await browser.newContext();
    const other = await second.newPage();
    try {
      await h.gotoApp(other);
      await h.selectSession(other, sessionId);
      await openAppearance(other);

      const chip = other.locator(`[data-custom-theme-id="${row.id}"]`);
      await expect(chip).toBeVisible();

      // B 端选中它：外壳 bg0/body 背景 + 终端 xterm 调色板真身一起翻。
      await chip.click();
      await expect(other.locator("html")).toHaveAttribute("data-theme", "dark");
      await expect.poll(() => cssVarBg0(other)).toBe(CUSTOM_BG0);
      await expect.poll(() => bodyBg(other)).toBe(CUSTOM_BG0_RGB);
      await expect.poll(() => termThemeBg(other)).toBe(CUSTOM_TERM);
    } finally {
      await second.close();
    }
  });

  test("fork 预设：复制内置主题→改一色→保存→选中，外壳跟着变；内置预设无删除控件", async ({
    page,
  }) => {
    await openAppearance(page);

    // 内置预设：有「复制」控件，绝无「删除」控件。
    const builtin = (await listThemesRpc(page)).find((t) => t.builtin);
    expect(builtin, "a built-in preset should exist").toBeTruthy();
    await expect(page.locator(`[data-fork-theme-id="${builtin.id}"]`)).toHaveCount(1);
    await expect(page.locator(`[data-delete-theme-id="${builtin.id}"]`)).toHaveCount(0);

    // 复制该预设 → 编辑器打开为副本草稿（名字带「副本」）。
    await page.locator(`[data-fork-theme-id="${builtin.id}"]`).click();
    await expect(page.locator("#theme-editor")).toBeVisible();
    await expect(page.locator("#theme-name-input")).toHaveValue(/副本|copy/i);
    const forkName = `E2E Fork ${Math.floor(Math.random() * 1e9)}`;
    await page.locator("#theme-name-input").fill(forkName);

    // 改一色后保存 —— 保存即选中，外壳立刻用新 bg0 重绘。
    await page.locator("#theme-hex-bg0").fill("#0f0f0f");
    await page.locator("#save-theme-button").click();
    await expect(page.locator("#theme-editor")).toHaveCount(0);
    await expect.poll(() => cssVarBg0(page)).toBe("#0f0f0f");

    const row = (await listThemesRpc(page)).find((t) => t.name === forkName);
    expect(row, "the fork should be a new owned row").toBeTruthy();
    expect(row.builtin).toBeFalsy();
    createdIds.push(row.id);
  });

  test("首帧缓存：选中自定义主题后刷新，首帧 --color-bg0 已是自定义值（命中缓存，不闪回基色）", async ({
    page,
  }) => {
    const name = `E2E Cache ${Math.floor(Math.random() * 1e9)}`;
    const theme = await createThemeRpc(page, {
      name,
      base: "dark",
      tokens: { bg0: CUSTOM_BG0, termBackground: CUSTOM_TERM },
    });
    createdIds.push(theme.id);

    // 通过 UI 选中它（会把主题写进 dala:theme:cache）。
    await openAppearance(page);
    const chip = page.locator(`[data-custom-theme-id="${theme.id}"]`);
    await expect(chip).toBeVisible();
    await chip.click();
    await expect.poll(() => cssVarBg0(page)).toBe(CUSTOM_BG0);

    // 刷新：spa_root 的 no-FOUC 内联脚本在首帧前就从缓存把自定义色刷上。
    await page.reload();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    // load 事件时内联脚本已跑完 —— 首帧即自定义值，不曾闪回基色 #0b0c0e。
    expect(await cssVarBg0(page)).toBe(CUSTOM_BG0);
  });

  test("亮色微调：分段控件选中态与轨道明显有别；Toggle 选中滑块用 bg0 派生色", async ({
    page,
  }) => {
    await openAppearance(page);

    // 切到亮色，让本次断言在亮色（问题最明显）下进行。
    await page.locator('[data-theme-setting="light"]').click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "light");

    // 分段控件：选中段是“凸起”的 bg0 药丸，轨道是“凹陷”的 bg2 井 —— 两者必须有别。
    // 选中段有 transition-colors，用 poll 等动画落定再取稳定色。
    const bgOf = (sel) =>
      page.locator(sel).evaluate((el) => getComputedStyle(el).backgroundColor);
    await expect.poll(() => bgOf('[data-theme-setting="light"]')).toBe("rgb(251, 251, 250)"); // bg0 亮
    const trackBg = await bgOf("#theme-setting-control");
    expect(trackBg).toBe("rgb(232, 232, 228)"); // bg2 亮 —— 凹陷的井
    const selectedBg = await bgOf('[data-theme-setting="light"]');
    expect(selectedBg).not.toBe(trackBg); // 药丸明显区别于轨道

    // Toggle 选中滑块：bg0 派生色（亮色下近白），不再是写死的 bg-black/80。
    // cursorBlink 默认开 → #cursor-blink-checkbox 处于选中态。
    await expect.poll(() => bgOf("#cursor-blink-checkbox ~ span")).toBe("rgb(251, 251, 250)"); // bg0 亮
  });
});
