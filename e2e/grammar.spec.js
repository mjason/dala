// TextMate 语法插件体系 — 项目级 dala.jsonc 声明的私有语法要在文件预览/
// 编辑器里真实着色（vscode-textmate + oniguruma wasm 全链路）。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const h = require("./helpers");

test.describe("Given 配置了项目级 TextMate 语法的用户", () => {
  let cwd;

  test.beforeEach(() => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-grammar-`);
    fs.mkdirSync(path.join(cwd, "syntaxes"));
    fs.writeFileSync(
      path.join(cwd, "syntaxes/dmx.tmLanguage.json"),
      JSON.stringify({
        name: "DMX",
        scopeName: "source.dmx",
        fileTypes: ["dmx"],
        patterns: [
          { match: "\\bmagic\\b", name: "keyword.control.dmx" },
          { match: '"[^"]*"', name: "string.quoted.dmx" },
        ],
      }),
    );
    fs.writeFileSync(
      path.join(cwd, "dala.jsonc"),
      `{
        // 私有语法，只在本机
        "grammars": [{ "path": "./syntaxes/dmx.tmLanguage.json" }],
      }`,
    );
    fs.writeFileSync(path.join(cwd, "demo.dmx"), 'magic "hello" plain words\n');
  });

  test.afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("自定义扩展名的文件按私有语法着色", async ({ page }) => {
    let s;
    try {
      await h.gotoApp(page);
      s = await h.createSession(page, cwd);
      await h.selectSession(page, s);
      await h.openDrawer(page);
      await page.click(`[data-path="${path.join(cwd, "demo.dmx")}"]`);

      const content = page.locator(".cm-content");
      await expect(content).toBeVisible();
      await expect(content).toContainText("magic");

      // keyword.control → 主题 keyword 色（内联 style 装饰，wasm 异步加载）。
      const keyword = page.locator('.cm-content span[style*="rgb(176, 135, 201)"]', { hasText: "magic" });
      await expect(keyword.first()).toBeVisible({ timeout: 15000 });
      const str = page.locator('.cm-content span[style*="rgb(95, 191, 135)"]', { hasText: '"hello"' });
      await expect(str.first()).toBeVisible();
    } finally {
      if (s) await h.deleteSession(page, s).catch(() => {});
    }
  });
  test("全局语法：设置里上传后生效，可删除", async ({ page }) => {
    // 待上传的语法（qmx 扩展名，避免与项目级用例互扰）。
    const grammarFile = path.join(cwd, "qmx.tmLanguage.json");
    fs.writeFileSync(
      grammarFile,
      JSON.stringify({
        name: "QMX",
        scopeName: "source.qmx",
        fileTypes: ["qmx"],
        patterns: [{ match: "\\bspell\\b", name: "keyword.control.qmx" }],
      }),
    );
    fs.writeFileSync(path.join(cwd, "demo.qmx"), "spell words\n");

    let s;
    try {
      await h.gotoApp(page);
      s = await h.createSession(page, cwd);
      await h.selectSession(page, s);

      // 设置 → 偏好设置 → 上传语法。
      await page.click("#session-settings-button");
      await page.click('[data-settings-tab="appearance"]');
      await page.setInputFiles('input[accept=".json"]', grammarFile);
      await expect(page.locator("[data-grammar-row]")).toContainText("QMX");
      await page.keyboard.press("Escape");

      // 打开 .qmx 文件：全局语法生效。
      await h.openDrawer(page);
      await page.click(`[data-path="${path.join(cwd, "demo.qmx")}"]`);
      const keyword = page.locator('.cm-content span[style*="rgb(176, 135, 201)"]', {
        hasText: "spell",
      });
      await expect(keyword.first()).toBeVisible({ timeout: 15000 });
      // 关掉预览弹窗（它盖住工具栏）。
      await page.keyboard.press("Escape");

      // 删除后列表清空。
      await page.click("#session-settings-button");
      await page.click('[data-settings-tab="appearance"]');
      await page.click("[data-grammar-delete]");
      await expect(page.locator("[data-grammar-row]")).toHaveCount(0);
    } finally {
      if (s) await h.deleteSession(page, s).catch(() => {});
    }
  });
});
