// 慢链路上的自适应行为。
//
// dala 里所有「按延迟分档」的东西 —— auto 本地回显、流控的 BDP 水位、
// holder 的帧窗口 —— 输入都是实测往返；而 e2e 跑在 localhost，往返 ~1ms。
// 也就是说在这个文件出现之前，这些策略的**慢链路那一半从来没有被任何测试
// 执行过**，只有单测覆盖。这里给 socket 注入真实延迟，把那一半跑起来。
const { test, expect } = require("./fixtures");
const h = require("./helpers");

// 单向延迟；往返是它的两倍。取 300 是因为它明显高于 auto 本地回显的 50ms
// 启用阈值，又不至于让整条用例慢到没法跑。
const ONE_WAY_MS = 300;
const ROUND_TRIP_MS = ONE_WAY_MS * 2;

const READY_TIMEOUT = 30_000;

const echoDelay = (page) => page.evaluate(() => window.__dalaFlow?.echoMs ?? null);
const ackedBytes = (page) => page.evaluate(() => window.__dalaFlow?.acked ?? 0);

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

async function readySession(page) {
  const id = await h.createSession(page, "/tmp");
  await h.selectSession(page, id);
  await expect(page.locator(".xterm").first()).toBeVisible();
  await expect.poll(() => ackedBytes(page), { timeout: READY_TIMEOUT }).toBeGreaterThan(0);
  // 等**提示符**，不是等第一个字节。慢链路上 shell 启动本身也慢，第一个
  // 字节到了不代表它已经在读输入 —— 早打的字会被直接吃掉。
  await expect
    .poll(() => bufferText(page), { timeout: READY_TIMEOUT })
    .toMatch(/[$#%>➜]/);
  return id;
}

// 打几个字把回显延迟的估计喂起来 —— auto 模式在拿到第一个样本之前不预测。
//
// 每个字之间等一整个往返再加 TUI 静默窗口：typeahead 认为「刚才那段输出
// 像是 TUI 重绘」时会主动让路 500ms，而花哨提示符（oh-my-zsh 之类）的
// 每次重绘都长得像 TUI 重绘。见下面那条用例的注释。
async function primeEchoMeter(page) {
  for (const char of "abcde") {
    await page.keyboard.type(char);
    await page.waitForTimeout(ROUND_TRIP_MS + 700);
  }
  await page.keyboard.press("Backspace");
  await page.waitForTimeout(ROUND_TRIP_MS + 700);
}

test.describe("Given 一条慢链路（单向 300ms）", () => {
  let id;

  test.beforeEach(async ({ page }) => {
    await h.withSocketLatency(page, ONE_WAY_MS);
    await h.gotoApp(page);
    id = await readySession(page);
  });

  test.afterEach(async ({ page }) => {
    if (id) await h.deleteSession(page, id).catch(() => {});
    id = null;
  });

  test("客户端量出了真实的往返 —— 三个自适应策略的输入是活的", async ({ page }) => {
    await primeEchoMeter(page);

    const measured = await echoDelay(page);
    expect(measured, "从未量到回显延迟：自适应策略全都在用默认值").not.toBeNull();

    // 量的是「按键 → 回显」，所以至少是一个往返（还要加上 shell 自己的时间）。
    expect(measured).toBeGreaterThan(ROUND_TRIP_MS * 0.6);
  });

  // 显式打开本地回显来验**机制**本身。
  //
  // 为什么不用 auto：typeahead 的「像 TUI 重绘就让路」启发式（TUI_OUTPUT
  // 正则）会把**花哨提示符的重绘**也算进去 —— e2e 的 shell 是 oh-my-zsh
  // （提示符 `➜`），它每次回显都带光标定位/擦行序列，于是每敲一个字都会
  // 触发 500ms 静默窗口。结果是 auto 在这种 shell 上几乎永远不预测。
  // 这是产品的真实局限，不是测试的毛病，所以这里不去迁就它：机制用 "on"
  // 验，测量用上面那条用例验。
  test("本地回显把字符立刻画出来，不等那 600ms 往返", async ({ page, context }) => {
    await context.addInitScript(() => {
      localStorage.setItem("dala:term-prefs", JSON.stringify({ localEcho: "on" }));
    });
    await page.reload();
    const localId = await readySession(page);

    try {
      // 预测是本地画的，所以必须远早于一个往返就可见。给 250ms —— 只有本地
      // 回显真的接管了才可能达到。
      await page.keyboard.type("Z");
      await expect
        .poll(() => bufferText(page), { timeout: 250, intervals: [20] })
        .toContain("Z");
      await page.keyboard.press("Backspace");
    } finally {
      await h.deleteSession(page, localId).catch(() => {});
    }
  });

  test("慢链路上终端依然可用：命令跑得起来，输出到得了", async ({ page }) => {
    await page.keyboard.type("printf 'SLOWLINKOK\\n'");
    await page.keyboard.press("Enter");
    await expect
      .poll(() => bufferText(page), { timeout: READY_TIMEOUT })
      .toContain("SLOWLINKOK");
  });

  test("慢链路 + alternate screen：增量帧照样画对", async ({ page }) => {
    await page.keyboard.type(
      "printf '\\033[?1049h\\033[H\\033[2J\\033[3;7HSLOWALT'; sleep 0.5; printf '\\033[?1049l'",
    );
    await page.keyboard.press("Enter");

    await expect
      .poll(() => bufferText(page), { timeout: READY_TIMEOUT })
      .toContain("SLOWALT");
  });
});

test.describe("Given 一条本地链路（对照组）", () => {
  let id;

  test.beforeEach(async ({ page }) => {
    await h.gotoApp(page);
    id = await readySession(page);
  });

  test.afterEach(async ({ page }) => {
    if (id) await h.deleteSession(page, id).catch(() => {});
    id = null;
  });

  test("localhost 上 auto 本地回显保持惰性 —— 只测量，不预测", async ({ page }) => {
    for (const char of "abcde") {
      await page.keyboard.type(char);
      await page.waitForTimeout(120);
    }
    await page.keyboard.press("Backspace");

    const measured = await echoDelay(page);
    if (measured === null) return; // 一个样本都没量到就没什么可断言的

    // 快链路必须落在启用阈值以下，否则 auto 会在本地也开始预测 —— 那正是
    // 「本地不该付这个代价」的反面。
    expect(measured).toBeLessThan(50);
  });
});
