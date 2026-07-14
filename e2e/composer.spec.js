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

  test("长草稿：编辑器随内容增高但有上限，终端与工具行不被遮住", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);

    const before = (await page.locator("#composer-editor").boundingBox()).height;

    // 30 行长草稿：编辑器应当增高（Enter 是换行，发送是 Shift+Enter）。
    const draft = Array.from({ length: 30 }, (_, i) => `line ${i}`).join("\n");
    await page.keyboard.type(draft);

    const box = await page.locator("#composer-editor").boundingBox();
    expect(box.height).toBeGreaterThan(before + 40);

    // 上限：不超过视口高度的 ~45%，终端和工具行仍然可见。
    const viewport = page.viewportSize();
    expect(box.height).toBeLessThanOrEqual(viewport.height * 0.45);
    await expect(page.locator("#input-bar-send")).toBeVisible();
    const term = await page.locator(".xterm").first().boundingBox();
    expect(term.height).toBeGreaterThan(100);

    // 超过上限后编辑器内部滚动（滚动条真的在动）。
    const scrolled = await page.evaluate(() => {
      const s = document.querySelector("#composer-editor .cm-scroller");
      return s ? s.scrollHeight > s.clientHeight && s.scrollTop > 0 : false;
    });
    expect(scrolled).toBe(true);
  });

  test("全屏按钮覆盖会话区，Esc 先退全屏、再按才关 composer", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);

    await page.locator("#composer-fullscreen").click();
    await expect(page.locator('#input-bar[data-fullscreen="true"]')).toBeVisible();

    // 覆盖整个会话区（App 的 main 区域），而不是原来贴底的一条。
    const viewport = page.viewportSize();
    const bar = await page.locator("#input-bar").boundingBox();
    expect(bar.height).toBeGreaterThan(viewport.height * 0.7);

    // 第一次 Esc：只退出全屏，composer 仍然打开。
    await page.keyboard.press("Escape");
    await expect(page.locator('#input-bar[data-fullscreen="true"]')).toHaveCount(0);
    await expect(page.locator("#composer-editor")).toBeVisible();

    // 第二次 Esc：才关闭 composer 本体。
    await page.keyboard.press("Escape");
    await expect(page.locator("#composer-editor")).toHaveCount(0);
  });

  test("带长草稿重开 composer：视图滚到底部，最后一行可见", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);

    const draft = Array.from({ length: 30 }, (_, i) => `line ${i}`).join("\n");
    await page.keyboard.type(draft);

    // 关闭（草稿保留在父组件），再重开。
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toHaveCount(0);
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();

    // 光标在末尾且视图滚到了底部——用户看到的是草稿结尾，不是开头。
    // 16px 余量：scrollIntoView(y:"end") 把光标行底边对齐可视区底边，
    // .cm-content 的 6px 下内边距会留在视口外，属于正常对齐结果。
    await expect
      .poll(() =>
        page.evaluate(() => {
          const s = document.querySelector("#composer-editor .cm-scroller");
          return s ? s.scrollTop + s.clientHeight >= s.scrollHeight - 16 : false;
        }),
      )
      .toBe(true);
    // 最后一行真实可见（IntersectionObserver 会考虑滚动容器的裁剪）。
    await expect(page.locator("#composer-editor .cm-line").last()).toHaveText("line 29");
    await expect(page.locator("#composer-editor .cm-line").last()).toBeInViewport();
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
