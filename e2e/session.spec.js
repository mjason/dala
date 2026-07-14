// 会话生命周期 — 创建与删除都能在侧栏里看到结果。
// 终端内容走 WebGL 渲染，DOM 里读不到文字：这里只断言 .xterm 挂载即“终端就绪”。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const h = require("./helpers");

/** __dalaTerm 读整个 active buffer 的文本(WebGL 下 DOM 没有文字)。 */
async function bufferText(page) {
  return page.evaluate(() => {
    const term = window.__dalaTerm;
    const buf = term?.buffer.active;
    if (!buf) return "";
    const lines = [];
    for (let i = 0; i < buf.length; i++) {
      lines.push(buf.getLine(i)?.translateToString(true) ?? "");
    }
    return lines.join("\n");
  });
}

/** 等 shell 就绪且 xterm 的隐藏 textarea 拿到焦点,之后才能用 keyboard 输入。 */
async function waitTerminalReady(page) {
  await expect
    .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 15_000 })
    .toBeGreaterThan(0);
  await expect
    .poll(
      () =>
        page.evaluate(
          () =>
            document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
        ),
      { timeout: 10_000 },
    )
    .toBe(true);
}

test.describe("Given 一个打开 dala 的用户", () => {
  let cwd;

  test.beforeEach(() => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-session-`);
  });

  test.afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("用户创建新会话后，会话出现在侧栏且终端就绪", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      // session_created 走 lobby channel 广播，侧栏应实时出现该条目。
      await expect(h.sessionEntry(page, id)).toBeVisible();
      // 唯一会话自动成为 active —— 终端视图挂载即就绪。
      await expect(page.locator(".xterm").first()).toBeVisible();
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("用户在全屏 TUI 里点重置后,终端当场重绘且焦点回到终端", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    try {
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);

      // 打开一个 alt-screen TUI(less):\f 这类"求 shell 重绘"的招数在
      // TUI 里会被吞掉——这正是旧版重置按钮把终端弄成黑屏的场景。
      await page.keyboard.type("less /etc/passwd");
      await page.keyboard.press("Enter");
      await expect
        .poll(
          async () =>
            (await page.evaluate(() => window.__dalaTerm?.buffer.active.type)) === "alternate"
              ? bufferText(page)
              : "",
          { timeout: 15_000 },
        )
        .toContain("root:");

      // 点工具栏"重置":不切走会话,holder 快照应以 reset replay 到达。
      const resetsBefore = await page.evaluate(() => window.__dalaFlow?.resets ?? 0);
      await page.locator("#terminal-reset-button").click();
      await expect
        .poll(() => page.evaluate(() => window.__dalaFlow?.resets ?? 0), { timeout: 15_000 })
        .toBeGreaterThan(resetsBefore);

      // 快照重绘出 less 的 alt-screen 内容——终端不是黑的。
      await expect.poll(() => bufferText(page), { timeout: 15_000 }).toContain("root:");

      // 焦点已还给终端(按钮点击本来会抢走焦点,旧版要切走再切回)。
      await expect
        .poll(
          () =>
            page.evaluate(
              () =>
                document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
            ),
          { timeout: 10_000 },
        )
        .toBe(true);

      // 立即可打字:q 退出 less,回到普通缓冲。replay 落地瞬间输入闸门
      // 可能还没放行,所以按键放进 poll 里重试(多余的 q 只是提示符上的
      // 一个字符,会话随即删除,无害)。
      await expect
        .poll(
          async () => {
            await page.keyboard.press("q");
            return page.evaluate(() => window.__dalaTerm?.buffer.active.type);
          },
          { timeout: 10_000 },
        )
        .toBe("normal");
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("用户删除会话后，会话从侧栏消失", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    try {
      const entry = h.sessionEntry(page, id);
      await expect(entry).toBeVisible();
      // 删除按钮 hover 才显示；点击后弹确认框，再点确认。
      await entry.hover();
      await entry.locator(`button[data-delete-session="${id}"]`).click();
      await page.locator("#confirm-delete-button").click();
      await expect(entry).toHaveCount(0);
    } finally {
      // 兜底清理：正常路径下会话已经删掉，RPC 会失败，忽略即可。
      await h.deleteSession(page, id).catch(() => {});
    }
  });
});
