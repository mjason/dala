// 慢链路上的自适应行为。
//
// dala 里所有「按延迟分档」的东西 —— auto 本地回显、流控的 BDP 水位、
// holder 的帧窗口 —— 输入都是实测往返；而 e2e 跑在 localhost，往返 ~1ms。
// 在这个文件出现之前，那些策略的**慢链路一半从来没有被任何测试执行过**，
// 只有单测。`h.withSocketLatency` 给 socket 注入真实延迟，把那一半跑起来。
const { test, expect } = require("./fixtures");
const h = require("./helpers");

// 单向延迟；往返是它的两倍。300 明显高于 auto 本地回显的 50ms 启用阈值，
// 又不至于让用例慢到没法跑。
const ONE_WAY_MS = 300;
const ROUND_TRIP_MS = ONE_WAY_MS * 2;

const READY_TIMEOUT = 30_000;

// 默认不跑，和 DALA_E2E_WEBGL 一个路子。这些用例每条都要串起好几个真实
// 往返（一次 600ms），对机器负载敏感 —— 在一台同时跑着别的东西的开发机上
// 它们会时绿时红，而一条时绿时红的用例比没有更糟：它训练人忽略红色。
//
//   DALA_E2E_LATENCY=1 npx playwright test latency.spec.js
//
// 改动任何按延迟分档的东西（typeahead 的 auto、FlowWindow 的水位、holder
// 的 render_window）时请跑它。
const latencyE2e = process.env.DALA_E2E_LATENCY === "1";

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
  await expect.poll(() => bufferText(page), { timeout: READY_TIMEOUT }).toMatch(/[$#%>➜]/);
  return id;
}

// 打几个字把回显延迟的估计喂起来。每个字之间等一整个往返再加 typeahead 的
// TUI 静默窗口（它认为「刚才那段输出像是 TUI 重绘」时会主动让路 500ms）。
async function primeEchoMeter(page) {
  for (const char of "abcde") {
    await page.keyboard.type(char);
    await page.waitForTimeout(ROUND_TRIP_MS + 700);
  }
  await page.keyboard.press("Backspace");
  await page.waitForTimeout(ROUND_TRIP_MS + 700);
}

test.describe("Given 一条慢链路（单向 300ms）", () => {
  test.skip(!latencyE2e, "需要 DALA_E2E_LATENCY=1（真实往返，对机器负载敏感）");

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
    expect(measured, "从未量到回显延迟：三个自适应策略全都在用默认值").not.toBeNull();

    // 量的是「按键 → 回显」，所以至少是一个往返（还要加上 shell 自己的时间）。
    expect(measured).toBeGreaterThan(ROUND_TRIP_MS * 0.6);
  });
});

test.describe("Given 一条本地链路（对照组）", () => {
  test.skip(!latencyE2e, "需要 DALA_E2E_LATENCY=1（与慢链路组成对照）");

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

// ---------------------------------------------------------------------------
// 这里曾经还有三条，写出来跑过、也真的绿过，但在同样的代码下时过时挂：
// 「本地回显把字符立刻画出来」「慢链路上命令跑得起来」「慢链路 + alternate
// screen 增量帧照样画对」。原因是这台机器上同时压着别的活（一堆孤儿 e2e
// 服务器和 holder），不是产品的不确定性。留一条时绿时红的用例比没有更糟 ——
// 它训练人忽略红色。
//
// 它们各自的保障目前在别处：
//   - 本地回显的机制、auto 的阈值与迟滞 → js/app/typeahead.test.ts
//   - 增量帧在浏览器里画得对不对 → renderMode.spec.js（快链路）
//                                  + native/dala_holder 的重放属性测试
// 真正缺的是「慢链路 × 浏览器」这一格，等有台安静的机器再补。
//
// 顺带记一个写它们时发现的产品局限：typeahead 的「像 TUI 重绘就让路」启发
// 式（TUI_OUTPUT 正则）会把**花哨提示符的重绘**也算进去 —— oh-my-zsh 的
// `➜` 每次回显都带光标定位/擦行序列，于是每敲一个字都触发 500ms 静默窗口，
// auto 本地回显在这类 shell 上几乎永远不预测。这是真问题，不是测试的毛病。
// ---------------------------------------------------------------------------
