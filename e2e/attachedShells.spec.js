// 会话内的附带 shell（tmux 分页模型）：主 shell 是第一个 tab，附带 shell 排在后面，
// 各自独立 PTY，能跑 rails s 这类长任务。断言走服务端副作用（落盘文件）与 tab DOM，
// 不读终端文字（WebGL 渲染，DOM 里没有）。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const h = require("./helpers");

/**
 * `__dalaFlow`/`__dalaTerm` are globals owned by whichever terminal is
 * visible, so polling them alone can read the PREVIOUS tab's numbers. Pin the
 * expected tab first, then wait for that terminal to have acked bytes.
 */
async function waitTabReady(page, tabId) {
  if (tabId) await expect(activeTab(page)).toHaveAttribute("data-session-tab", tabId);
  await expect
    .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 15_000 })
    .toBeGreaterThan(0);
  // Whether clicking a sidebar row hands the keyboard to the terminal is
  // sidebar.spec's business; here we only need typing to be possible.
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

const waitTerminalReady = (page) => waitTabReady(page, null);

async function runInTerminal(page, command) {
  await page.keyboard.type(command);
  await page.keyboard.press("Enter");
}

const tabs = (page) => page.locator("[data-session-tab]");
const activeTab = (page) => page.locator('[data-session-tab][data-active="true"]');

/** 点 + 开一个附带 shell，返回它的 tab locator。 */
async function addShellTab(page) {
  const before = await tabs(page).count();
  await page.locator("#session-tab-add").click();
  await expect(tabs(page)).toHaveCount(before + 1);

  const tab = tabs(page).nth(before);
  await waitTabReady(page, await tab.getAttribute("data-session-tab"));
  return tab;
}

test.describe("Given 一个会话需要额外的 shell", () => {
  let cwd;
  let ids;

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-tabs-`);
    ids = [];
    await page.addInitScript(() => localStorage.setItem("dala:drawer-open", "0"));
  });

  test.afterEach(async ({ page }) => {
    // 删父会话会连带删掉它的附带 shell。
    for (const id of ids) await h.deleteSession(page, id).catch(() => {});
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("主 shell 是第一个 tab，+ 开出来的附带 shell 排在后面且独立运行", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    ids.push(id);
    await h.selectSession(page, id);
    await waitTerminalReady(page);

    // 只有主 shell 时也有 tab 栏，第一个 tab 就是它。
    await expect(tabs(page)).toHaveCount(1);
    await expect(tabs(page).first()).toHaveAttribute("data-session-tab", id);

    await addShellTab(page);
    await expect(activeTab(page)).not.toHaveAttribute("data-session-tab", id);

    // 新 tab 是另一个 shell：在它里面落一个只有它能落的文件。
    const marker = path.join(cwd, "from-attached-shell");
    await runInTerminal(page, `touch ${marker}`);
    await expect.poll(() => fs.existsSync(marker), { timeout: 20_000 }).toBe(true);

    // 侧栏不列附带 shell，只在父行上挂角标。
    await expect(page.locator(`[data-attached-count="${id}"]`)).toHaveText("⌗1");
    await expect(h.sessionEntry(page, id)).toBeVisible();
  });

  test("长任务在自己的 tab 里继续跑，切走再切回来还在", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    ids.push(id);
    await h.selectSession(page, id);
    await waitTerminalReady(page);
    await addShellTab(page);

    // 后台长任务：持续写心跳，切换 tab 不该打断它。
    const beats = path.join(cwd, "beats");
    await runInTerminal(page, `(while true; do echo tick >> ${beats}; sleep 0.2; done) &`);
    await expect.poll(() => fs.existsSync(beats), { timeout: 20_000 }).toBe(true);

    await tabs(page).first().click();
    await expect(activeTab(page)).toHaveAttribute("data-session-tab", id);

    const seen = fs.readFileSync(beats, "utf8").length;
    await page.waitForTimeout(1_000);
    expect(fs.readFileSync(beats, "utf8").length).toBeGreaterThan(seen);

    // 切回附带 shell：tab 还在，仍然是活的。
    await tabs(page).nth(1).click();
    await expect(activeTab(page)).not.toHaveAttribute("data-session-tab", id);
  });

  test("刷新页面后 tab 与它里面的进程都还在", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    ids.push(id);
    await h.selectSession(page, id);
    await waitTerminalReady(page);
    await addShellTab(page);

    const beats = path.join(cwd, "beats-reload");
    await runInTerminal(page, `(while true; do echo tick >> ${beats}; sleep 0.2; done) &`);
    await expect.poll(() => fs.existsSync(beats), { timeout: 20_000 }).toBe(true);

    await page.reload();
    await h.gotoApp(page);
    await h.selectSession(page, id);

    await expect(tabs(page)).toHaveCount(2);

    // holder 独立于浏览器存活，心跳不该断。
    const seen = fs.readFileSync(beats, "utf8").length;
    await page.waitForTimeout(1_000);
    expect(fs.readFileSync(beats, "utf8").length).toBeGreaterThan(seen);
  });

  test("在附带 shell 里 exit 只关掉这一个 tab，回到主 shell", async ({ page }) => {
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    ids.push(id);
    await h.selectSession(page, id);
    await waitTerminalReady(page);
    await addShellTab(page);

    await runInTerminal(page, "exit");

    await expect(tabs(page)).toHaveCount(1);
    await expect(activeTab(page)).toHaveAttribute("data-session-tab", id);
    await expect(page.locator(`[data-attached-count="${id}"]`)).toHaveCount(0);
    // 主 shell 没有被牵连（没有"已退出"浮层）。
    await expect(page.locator("#overlay-restart-button")).toHaveCount(0);
  });

  test("删除会话时它的附带 shell 一起消失", async ({ page }) => {
    await h.gotoApp(page);
    const keep = await h.createSession(page, cwd);
    const doomed = await h.createSession(page, cwd);
    ids.push(keep);

    await h.selectSession(page, doomed);
    await waitTerminalReady(page);
    await addShellTab(page);
    await addShellTab(page);
    await expect(page.locator(`[data-attached-count="${doomed}"]`)).toHaveText("⌗2");

    await h.deleteSession(page, doomed);

    // 父行连同角标一起消失，附带 shell 不会变成孤儿留在侧栏。
    await expect(h.sessionEntry(page, doomed)).toHaveCount(0);
    await expect(page.locator("[data-attached-count]")).toHaveCount(0);
    await expect(h.sessionEntry(page, keep)).toBeVisible();
  });
});
