// 设置面板 — 打开与逐 tab 切换时不得有任何未捕获错误。
//
// 已有的 settings.spec.js 只断言布局和语音 tab 的读写，从不看控制台：一个
// 让 <SettingsModal> 整棵子树崩掉、页面变白的 React 错误可以让那七条用例
// 全绿。这里补的就是那一层 —— 每条用例都把 pageerror 和 console.error
// 当作失败，并且真的把每个 tab 都点开一遍。
const { test, expect } = require("@playwright/test");
const h = require("./helpers");

// React 的 "useEffect must not return anything besides a function" 之类只是
// console.error；真正炸掉渲染的是随后的 pageerror。两个都要收。
function watchForFailures(page) {
  const failures = [];

  page.on("pageerror", (error) => {
    failures.push(`pageerror: ${error.message}`);
  });
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    const text = message.text();
    // 网络层的噪音（断线重连、被取消的请求）不是渲染健康度问题。
    if (/Failed to load resource|net::ERR_|WebSocket/.test(text)) return;
    failures.push(`console.error: ${text}`);
  });

  return failures;
}

test.describe("Given 用户打开会话的设置面板", () => {
  let sessionId;
  let failures;

  test.beforeEach(async ({ page }) => {
    failures = watchForFailures(page);
    await h.gotoApp(page);
    sessionId = await h.createSession(page, "/tmp");
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
  });

  test("按下设置按钮：面板打开，页面没有崩", async ({ page }) => {
    await page.locator("#session-settings-button").click();
    await expect(page.locator("#session-settings")).toBeVisible();

    // 崩溃的表现是整棵子树被 React 卸载 —— 弹窗还在 DOM 里但内容没了，
    // 或者干脆整页白屏。两样都验一下。
    await expect(page.locator("#settings-body")).toBeVisible();
    await expect(page.locator("#save-settings-button")).toBeVisible();

    expect(failures, `打开设置面板时出现未捕获错误:\n${failures.join("\n")}`).toEqual([]);
  });

  test("每个 tab 都点开一遍：没有一页会炸", async ({ page }) => {
    await page.locator("#session-settings-button").click();
    await expect(page.locator("#session-settings")).toBeVisible();

    const tabs = page.locator("#session-settings [role='tab']");
    const count = await tabs.count();
    expect(count).toBeGreaterThan(0);

    for (let index = 0; index < count; index++) {
      const tab = tabs.nth(index);
      const label = (await tab.textContent())?.trim();
      await tab.click();
      await expect(page.locator("#settings-body")).toBeVisible();
      // 保存按钮活着 = 弹窗这棵树还完整。
      await expect(page.locator("#save-settings-button")).toBeVisible();
      expect(failures, `「${label}」tab 出现未捕获错误:\n${failures.join("\n")}`).toEqual([]);
    }
  });

  // 外观 tab 上的分段控件（主题 / 光标 / 本地回显）。切换会立刻改主题并写
  // localStorage，是这一页里唯一有副作用的交互。
  test("外观 tab：三个分段控件都能切且不报错", async ({ page }) => {
    await page.locator("#session-settings-button").click();
    await page.locator('[data-settings-tab="appearance"]').click();

    await expect(page.locator("#theme-setting-control")).toBeVisible();
    await expect(page.locator("#cursor-style-control")).toBeVisible();
    await expect(page.locator("#local-echo-control")).toBeVisible();

    await page.locator("[data-theme-setting='light']").click();
    await expect(page.locator("[data-theme-setting='light']")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await page.locator("[data-cursor-style='block']").click();
    await expect(page.locator("[data-cursor-style='block']")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await page.locator("[data-local-echo='on']").click();
    await expect(page.locator("[data-local-echo='on']")).toHaveAttribute("aria-pressed", "true");

    // 本地回显是浏览器级偏好，必须落到 localStorage 才算真的切了。
    const stored = await page.evaluate(
      () => JSON.parse(localStorage.getItem("dala:term-prefs") || "{}").localEcho,
    );
    expect(stored).toBe("on");

    expect(failures, `外观 tab 出现未捕获错误:\n${failures.join("\n")}`).toEqual([]);
  });
});
