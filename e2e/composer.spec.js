// 富文本输入条（composer）— 快捷键三态循环里的“开 → 聚焦”和“关 → 焦点回终端”。
// composer 是 CodeMirror（#composer-editor .cm-content），内容 DOM 可读；
// 终端本体是 WebGL 渲染，焦点落在 xterm 的隐藏 textarea 上。
const { test, expect } = require("@playwright/test");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const h = require("./helpers");

test.describe("Given 一个有活动会话的用户", () => {
  let cwd;
  let sessionId;

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-composer-`);
    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("用户按快捷键 Ctrl+Shift+K 打开 composer 并获得焦点", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    // 焦点应落在编辑器内部（CodeMirror 的 contenteditable）。
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);
  });

  test("关闭后焦点回到终端", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);

    // 已打开且已聚焦时，再按一次快捷键 = 关闭并把焦点交还终端。
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toHaveCount(0);
    await expect
      .poll(() =>
        page.evaluate(() =>
          Boolean(document.activeElement?.classList?.contains("xterm-helper-textarea")),
        ),
      )
      .toBe(true);
  });
});

// @ 文件引用：git 仓库中的会话，中文文件名 + 完整绝对路径都要能匹配，
// .gitignore 忽略的文件绝不出现（服务端用 git ls-files 列表）。
test.describe("Given 一个位于 git 仓库的会话（@ 文件引用）", () => {
  const chineseFile = "strategies/选币研究demo.py";
  const spacedFile = "strategies/选币 研究demo.py";
  let cwd;
  let sessionId;

  /** 清空 composer 草稿（CodeMirror 的全选 + 删除）。
   *  Control+A 是 Linux/Windows 的全选（macOS 是 Meta+A）；e2e 只跑
   *  Linux，所以这里写死 Control。 */
  async function clearDraft(page) {
    await page.keyboard.press("Control+A");
    await page.keyboard.press("Backspace");
  }

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-mention-`);
    cp.execSync("git init -q", { cwd });
    fs.mkdirSync(path.join(cwd, "strategies"));
    fs.mkdirSync(path.join(cwd, "junk"));
    fs.writeFileSync(path.join(cwd, ".gitignore"), "junk/\n");
    fs.writeFileSync(path.join(cwd, chineseFile), "# demo\n");
    fs.writeFileSync(path.join(cwd, spacedFile), "# spaced demo\n");
    fs.writeFileSync(path.join(cwd, "junk/build.log"), "noise\n");

    await h.gotoApp(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);

    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    // 焦点是异步落到 CodeMirror 的：先等真正聚焦再打字，否则开头字符会丢。
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("@中文前缀、@完整绝对路径都能匹配，忽略文件不出现", async ({ page }) => {
    const item = page.locator(`[data-mention-item="${chineseFile}"]`);

    // 中文前缀匹配。
    await page.keyboard.type("@选币");
    await expect(item).toBeVisible();

    // 完整绝对路径也要命中（root 前缀会被剥掉）。
    await clearDraft(page);
    await page.keyboard.type(`@${cwd}/${chineseFile}`);
    await expect(item).toBeVisible();

    // .gitignore 忽略的文件绝不出现在候选里。
    await clearDraft(page);
    await page.keyboard.type("@build.log");
    await expect(page.locator("[data-mention-item]")).toHaveCount(0);
  });

  test("选择带空格的文件名时插入反斜杠转义的路径", async ({ page }) => {
    // @ 后的 query 不允许空格：用户输入的是去掉空格的塌缩查询。
    await page.keyboard.type("@选币研究");
    const item = page.locator(`[data-mention-item="${spacedFile}"]`);
    await expect(item).toBeVisible();

    await item.click();

    // 裸空格会让 bash 和 claude 的 @ 引用在空格处断掉——必须插入
    // `选币\ 研究` 这种反斜杠转义形式。
    await expect(page.locator("#composer-editor .cm-content")).toContainText(
      "strategies/选币\\ 研究demo.py",
    );
  });
});
