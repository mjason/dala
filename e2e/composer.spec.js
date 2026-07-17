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

  // composer 的高度策略是一条状态机，历史上每一级都被改坏过（空态过高吃掉
  // 终端行、封顶失效遮住终端、退全屏后丢失有界高度）。这里按真实几何量
  // （boundingBox / scrollHeight / clientHeight，绝不查 class 名）逐级钉死：
  //   空态 ≈3 行 → 随内容生长 → 40% 视口封顶且内部滚动 → 全屏 →
  //   退全屏回到「有界高度」而不是空态 → 关闭 → 带草稿重开滚到底。
  test("composer 高度状态机：3 行起步 → 生长 → 40% 封顶内滚 → 全屏 → 退全屏回到有界高度 → 关闭 → 重开滚到底", async ({
    page,
  }) => {
    const viewport = page.viewportSize();
    const editorHeight = async () =>
      (await page.locator("#composer-editor").boundingBox()).height;

    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    await expect
      .poll(() =>
        page.evaluate(() => Boolean(document.activeElement?.closest("#composer-editor"))),
      )
      .toBe(true);

    // ① 初始态：空草稿只占 2 行 —— COMPOSER_MIN_HEIGHT = 3.375rem = 54px
    //    （.cm-content 是 border-box：12px 内边距 + 2×21px 行高，14px/1.5）。
    //    这也是全应用的"紧凑输入框"高度：git 提交框用同一个常量
    //    （COMPACT_FIELD_CLASS），两个框并排时必须像素级一致 —— 见下一条
    //    专门的对齐用例。±6px 容差：字体度量在不同机器上有亚像素差。
    //    从前是 7.5rem（≈5 行），空着就吃掉三行终端 —— 这条断言防它回来。
    const initial = await editorHeight();
    expect(initial).toBeGreaterThanOrEqual(48);
    expect(initial).toBeLessThanOrEqual(60);
    expect(initial).toBeLessThan(0.2 * viewport.height); // 空态绝不占大块视口

    // ② 自动生长：8 行草稿（> 3 行的地板）撑高编辑器。关键不变式：终端尺寸
    //    【一行都不动】—— composer 悬浮向上盖住终端底部，不再 per-keystroke
    //    reflow 终端（老设计正是在这里抖动/闪烁）。
    const rowsBefore = await page.evaluate(() => window.__dalaTerm?.rows);
    expect(rowsBefore).toBeGreaterThan(0);
    await page.keyboard.type(Array.from({ length: 8 }, (_, i) => `line ${i}`).join("\n"));
    const grown = await editorHeight();
    expect(grown).toBeGreaterThan(initial);
    expect(grown).toBeGreaterThan(initial + 40); // 至少多出好几行，不是抖动

    await expect(page.locator("#input-bar-send")).toBeVisible();
    // 长高零 resize：终端行数保持不变（悬浮方案的核心保证）。
    await expect
      .poll(() => page.evaluate(() => window.__dalaTerm?.rows))
      .toBe(rowsBefore);
    let term = await page.locator(".xterm").first().boundingBox();
    let bar = await page.locator("#input-bar").boundingBox();
    expect(term.height).toBeGreaterThan(100); // 终端保持满高，未被挤矮
    expect(bar.y).toBeLessThan(term.y + term.height); // composer 悬浮盖住终端底部

    // ③ 封顶：继续打到 40 行 —— 高度停在 min(40vh, --vvh*0.4)，编辑器内部
    //    滚动，光标所在的最后一行仍然可见。+2px 容差是边框/取整。
    await page.keyboard.type(
      "\n" + Array.from({ length: 32 }, (_, i) => `line ${i + 8}`).join("\n"),
    );
    const capped = await editorHeight();
    expect(capped).toBeGreaterThan(grown);
    expect(capped).toBeLessThanOrEqual(0.4 * viewport.height + 2);

    const scroller = await page.evaluate(() => {
      const s = document.querySelector("#composer-editor .cm-scroller");
      return { scrollHeight: s.scrollHeight, clientHeight: s.clientHeight, scrollTop: s.scrollTop };
    });
    expect(scroller.scrollHeight).toBeGreaterThan(scroller.clientHeight);
    expect(scroller.scrollTop).toBeGreaterThan(0); // 真的跟着光标滚了
    await expect(page.locator("#composer-editor .cm-line").last()).toHaveText("line 39");
    await expect(page.locator("#composer-editor .cm-line").last()).toBeInViewport();

    term = await page.locator(".xterm").first().boundingBox();
    expect(term.height).toBeGreaterThan(100); // 封顶的意义：终端还在

    // ④ 全屏：覆盖整个会话区（不是贴底的一条）。
    await page.locator("#composer-fullscreen").click();
    await expect(page.locator('#input-bar[data-fullscreen="true"]')).toBeVisible();
    bar = await page.locator("#input-bar").boundingBox();
    expect(bar.height).toBeGreaterThan(0.7 * viewport.height);

    //    第一次 Esc：只退全屏 —— 高度必须回到「封顶后的有界高度」，而不是
    //    塌回空态的 3 行（sizing compartment 要重新配置回有界策略）。
    await page.keyboard.press("Escape");
    await expect(page.locator('#input-bar[data-fullscreen="true"]')).toHaveCount(0);
    await expect(page.locator("#composer-editor")).toBeVisible();
    const restored = await editorHeight();
    expect(Math.abs(restored - capped)).toBeLessThanOrEqual(2);
    expect(restored).toBeGreaterThan(initial + 40);

    //    第二次 Esc：才关闭 composer 本体（草稿留在父组件里）。
    await page.keyboard.press("Escape");
    await expect(page.locator("#composer-editor")).toHaveCount(0);

    // ⑤ 带长草稿重开：视图滚到底部，用户看到的是草稿结尾而不是开头。
    //    16px 余量：scrollIntoView(y:"end") 把光标行底边对齐可视区底边，
    //    .cm-content 的 6px 下内边距会留在视口外，属于正常对齐结果。
    await page.keyboard.press("Control+Shift+K");
    await expect(page.locator("#composer-editor")).toBeVisible();
    expect(Math.abs((await editorHeight()) - capped)).toBeLessThanOrEqual(2);
    await expect
      .poll(() =>
        page.evaluate(() => {
          const s = document.querySelector("#composer-editor .cm-scroller");
          return s ? s.scrollTop + s.clientHeight >= s.scrollHeight - 16 : false;
        }),
      )
      .toBe(true);
    await expect(page.locator("#composer-editor .cm-line").last()).toHaveText("line 39");
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

  test("粘贴图片：路径插入在光标处而不是末尾", async ({ page }) => {
    await page.keyboard.press("Control+Shift+K");
    const editor = page.locator("#composer-editor .cm-content");
    await expect(editor).toBeVisible();
    await editor.click();
    await page.keyboard.type("hello world");
    // 光标移到 "hello " 之后（"world" 前）。
    for (let i = 0; i < "world".length; i++) await page.keyboard.press("ArrowLeft");
    // 派发带 PNG 的粘贴事件。
    await page.evaluate(() => {
      const el = document.querySelector("#composer-editor .cm-content");
      const b64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
      const bytes = atob(b64);
      const arr = new Uint8Array(bytes.length);
      for (let i = 0; i < bytes.length; i++) arr[i] = bytes.charCodeAt(i);
      const dt = new DataTransfer();
      dt.items.add(new File([arr], "shot.png", { type: "image/png" }));
      el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true }));
    });
    // 上传完成后：路径替换占位符，位于 hello 与 world 之间。
    await expect
      .poll(async () => await editor.innerText(), { timeout: 10000 })
      .toMatch(/hello \/.*\/attachments\/.*\/shot\.png world/);
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

  test("composer 与 git 提交框像素级等高：两者共用同一个紧凑输入框高度常量", async ({
    page,
  }) => {
    // 两个输入框在桌面上并排出现（composer 在会话列底部、提交框在 git 面板
    // 底部）。它们各自的高度曾经独立演化（120px vs 53px，视觉上一高一低）。
    // 现在 GitPanel 的 textarea 用 composerSize.ts 的 COMPACT_FIELD_CLASS
    // 钉在同一个常量上 —— 这条断言防止任何一侧再次单独漂移。
    // composer 已由 beforeEach 打开（本 describe 的所有用例都从这个状态起步）。
    await expect(page.locator("#composer-editor")).toBeVisible();
    await page.keyboard.press("Control+Shift+G"); // git 面板（会话在 git 仓库里）
    const commit = page.locator("#commit-message-input");
    await expect(commit).toBeVisible();

    const heights = await page.evaluate(() => ({
      composer: document
        .querySelector("#composer-editor .cm-editor")
        .getBoundingClientRect().height,
      commit: document.querySelector("#commit-message-input").getBoundingClientRect()
        .height,
    }));

    // ±1px：两者的盒模型不同（CodeMirror 无边框、textarea 有 1px 边框），
    // 共享常量保证的是"渲染高度一致"，亚像素取整允许 1px 差。
    expect(Math.abs(heights.composer - heights.commit)).toBeLessThanOrEqual(1);
  });
});
