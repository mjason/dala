// 刷屏负载下的交互性 —— 一个会话把 PTY 灌满时，输入路径不能被输出挤死，
// 会话也不能被误判成“已退出”。断言全部走服务端副作用（落盘文件）和 UI 状态，
// 不读终端 DOM 文本（WebGL 渲染，DOM 里没有文字）。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const h = require("./helpers");

/**
 * 等 shell 就绪并把焦点显式交给终端。点击侧栏行是否顺带聚焦终端由
 * sidebar.spec.js 负责；这里只要输入路径确定可用。
 */
async function waitTerminalReady(page) {
  await expect
    .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 15_000 })
    .toBeGreaterThan(0);
  await page.evaluate(() => window.__dalaTerm?.focus());
  await expect
    .poll(
      () =>
        page.evaluate(
          () => document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
        ),
      { timeout: 10_000 },
    )
    .toBe(true);
}

async function runInTerminal(page, command) {
  await page.keyboard.type(command);
  await page.keyboard.press("Enter");
}

/** 后台刷屏：shell 立刻回到提示符，于是输入与洪水输出真正并发。 */
async function startBackgroundFlood(page) {
  // ~1.8MB —— 稳稳超过 holder 那 1MiB 的环形队列，掉帧与追平都会真的发生。
  await runInTerminal(page, "seq 1 250000 &");
}

function landed(file) {
  return expect.poll(() => fs.existsSync(file), { timeout: 25_000 }).toBe(true);
}

test.describe("Given 一个会话把输出灌满 PTY", () => {
  let cwd;
  let ids;

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-flood-`);
    ids = [];
    await page.addInitScript(() => localStorage.setItem("dala:drawer-open", "0"));
  });

  test.afterEach(async ({ page }) => {
    for (const id of ids) await h.deleteSession(page, id).catch(() => {});
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("刷屏期间敲入的命令仍然按时执行，且会话不被判死", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    ids.push(id);
    await h.selectSession(page, id);
    await waitTerminalReady(page);

    const marker = path.join(cwd, "typed-through-flood");
    await startBackgroundFlood(page);
    await runInTerminal(page, `touch ${marker}`);

    // 输入排在几千帧输出后面时，这个文件永远不会出现。
    await landed(marker);

    // 洪水让 holder 的写超时触发过，也只能重连，不能把活着的 shell 判死。
    await expect(page.locator("#overlay-restart-button")).toHaveCount(0);
  });

  test("刷屏结束后终端追上最新输出", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    ids.push(id);
    await h.selectSession(page, id);
    await waitTerminalReady(page);

    await startBackgroundFlood(page);
    await runInTerminal(page, "wait; printf 'caught-up-marker\\n'");

    // 中途丢帧是设计的一部分（holder 的环形队列有界）；追平靠权威快照。
    await expect
      .poll(
        () =>
          page.evaluate(() => {
            const buffer = window.__dalaTerm?.buffer.active;
            if (!buffer) return "";
            const lines = [];
            for (let i = 0; i < buffer.length; i++) {
              lines.push(buffer.getLine(i)?.translateToString(true) ?? "");
            }
            return lines.join("\n");
          }),
        { timeout: 30_000 },
      )
      .toContain("caught-up-marker");
  });

  test("后台会话刷屏时，当前会话的输入照样按时落地", async ({ page }) => {
    await h.gotoApp(page);
    const flooding = await h.createSession(page, cwd);
    const foreground = await h.createSession(page, cwd);
    ids.push(flooding, foreground);

    await h.selectSession(page, flooding);
    await waitTerminalReady(page);
    await startBackgroundFlood(page);

    // 切走之后刷屏会话在服务端继续产出（客户端不再收增量）。
    await h.selectSession(page, foreground);
    await waitTerminalReady(page);

    const marker = path.join(cwd, "foreground-stays-responsive");
    await runInTerminal(page, `touch ${marker}`);

    await landed(marker);
    await expect(page.locator("#overlay-restart-button")).toHaveCount(0);
  });
});
