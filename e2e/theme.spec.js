// 整体亮/暗主题 — UI 外壳与终端一起切换，且「跟随系统」实时跟随 OS 配色。
//
// 断言不看具体像素，只看主题 token 的落地效果：<html data-theme> 的值、
// body 背景（body:has(> #app) → var(--color-bg0)）、以及终端 .xterm-viewport
// 背景（app.css 里也钉在 var(--color-bg0)）。两处一起变，才算「整个 app 一起
// 换主题」。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const h = require("./helpers");

// --color-bg0：暗 #0b0c0e / 亮 #fbfbfa（app.css @theme 与 light 覆盖）。
const DARK_BG = "rgb(11, 12, 14)";
const LIGHT_BG = "rgb(251, 251, 250)";

// xterm 调色板真身：TerminalView 在 onThemeChange 时把整套 terminalTheme() 换给
// term.options.theme。上面的 body/viewport 背景都被 app.css 用 !important 钉在
// var(--color-bg0)，就算 xterm 调色板没翻它们也会变——所以那两个断言证明不了
// 终端调色板切换。这里直接读 xterm 自己持有的 theme.background（暗 #0b0c0e /
// 亮 #fbfbfa），才真正证明终端调色板跟着翻了。
const DARK_TERM = "#0b0c0e";
const LIGHT_TERM = "#fbfbfa";

const bodyBg = (page) =>
  page.evaluate(() => getComputedStyle(document.body).backgroundColor);
const viewportBg = (page) =>
  page.evaluate(() => {
    const vp = document.querySelector(".xterm-viewport");
    return vp ? getComputedStyle(vp).backgroundColor : null;
  });
// window.__dalaTerm 是主会话终端的调试句柄（TerminalView debugHandle）。
const termThemeBg = (page) =>
  page.evaluate(() => window.__dalaTerm?.options?.theme?.background ?? null);
const cssToken = (page, name) =>
  page.evaluate((token) => getComputedStyle(document.documentElement).getPropertyValue(token).trim(), name);

test.describe("Given 一个打开了终端会话的用户，在设置里切换主题", () => {
  let cwd;
  let sessionId;

  test.beforeEach(async ({ page }) => {
    cwd = `/tmp/dala-e2e-theme-${Math.floor(Math.random() * 1e9)}`;
    fs.mkdirSync(cwd, { recursive: true });
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("切到「亮」：外壳与终端一起变亮；切回「暗」：又一起变暗", async ({ page }) => {
    await page.setViewportSize({ width: 1000, height: 760 });
    const html = page.locator("html");
    await h.openSettings(page);
    await h.openSettingsTab(page, "appearance");
    await expect(page.locator("#theme-setting-control")).toBeVisible();
    const appearance = page.locator("#settings-body");

    // 亮：<html data-theme>、body 背景、终端 viewport 背景全部变亮，且 xterm
    // 调色板真身也翻到亮色背景。
    await page.locator('[data-theme-setting="light"]').click();
    await expect(html).toHaveAttribute("data-theme", "light");
    await expect.poll(() => bodyBg(page)).toBe(LIGHT_BG);
    await expect.poll(() => viewportBg(page)).toBe(LIGHT_BG);
    await expect.poll(() => termThemeBg(page)).toBe(LIGHT_TERM);
    await expect.poll(() => cssToken(page, "--color-git-added")).toBe("#116329");
    await expect.poll(() => cssToken(page, "--color-git-deleted")).toBe("#705f66");
    await expect.poll(() => cssToken(page, "--color-git-conflict")).toBe("#6639ba");

    // Stable visual baseline for the actual appearance panel. The e2e server
    // removes non-built-in themes from its isolated DB copy, so user-created
    // library rows cannot change the screenshot geometry.
    await expect(appearance).toHaveScreenshot("theme-light.png", {
      animations: "disabled",
      caret: "hide",
      maxDiffPixelRatio: 0.008,
      scale: "css",
    });

    // 暗：一起切回，xterm 调色板也翻回暗色背景。
    await page.locator('[data-theme-setting="dark"]').click();
    await expect(html).toHaveAttribute("data-theme", "dark");
    await expect.poll(() => bodyBg(page)).toBe(DARK_BG);
    await expect.poll(() => viewportBg(page)).toBe(DARK_BG);
    await expect.poll(() => termThemeBg(page)).toBe(DARK_TERM);
    await expect.poll(() => cssToken(page, "--color-git-added")).toBe("#5fbf87");
    await expect.poll(() => cssToken(page, "--color-git-deleted")).toBe("#b4a7ad");
    await expect.poll(() => cssToken(page, "--color-git-conflict")).toBe("#c9a5dd");
    await expect(appearance).toHaveScreenshot("theme-dark.png", {
      animations: "disabled",
      caret: "hide",
      maxDiffPixelRatio: 0.008,
      scale: "css",
    });
  });

  test("「跟随系统」：emulateMedia 切换 OS 配色，主题实时跟随，无需重连", async ({
    page,
  }) => {
    const html = page.locator("html");
    await h.openSettings(page);
    await h.openSettingsTab(page, "appearance");
    await page.locator('[data-theme-setting="system"]').click();

    // OS 亮 → app 亮，终端调色板一起翻。
    await page.emulateMedia({ colorScheme: "light" });
    await expect(html).toHaveAttribute("data-theme", "light");
    await expect.poll(() => bodyBg(page)).toBe(LIGHT_BG);
    await expect.poll(() => viewportBg(page)).toBe(LIGHT_BG);
    await expect.poll(() => termThemeBg(page)).toBe(LIGHT_TERM);

    // OS 暗 → app 暗（同一个已打开的终端就地重绘），调色板翻回暗色。
    await page.emulateMedia({ colorScheme: "dark" });
    await expect(html).toHaveAttribute("data-theme", "dark");
    await expect.poll(() => bodyBg(page)).toBe(DARK_BG);
    await expect.poll(() => viewportBg(page)).toBe(DARK_BG);
    await expect.poll(() => termThemeBg(page)).toBe(DARK_TERM);
  });

  test("手动覆盖胜过系统：设为「暗」后，OS 切到亮也不受影响", async ({ page }) => {
    const html = page.locator("html");
    await h.openSettings(page);
    await h.openSettingsTab(page, "appearance");

    await page.locator('[data-theme-setting="dark"]').click();
    await expect(html).toHaveAttribute("data-theme", "dark");

    // OS 切到亮：显式「暗」必须压过系统偏好。
    await page.emulateMedia({ colorScheme: "light" });
    await expect(html).toHaveAttribute("data-theme", "dark");
    await expect.poll(() => bodyBg(page)).toBe(DARK_BG);
  });
});
