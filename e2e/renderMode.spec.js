// Render mode, end to end in a real browser.
//
// The Rust side has a property test that replays every frame into a second
// emulator and compares text, styles and cursor; the Elixir side checks the
// bytes the holder emits. Neither involves xterm.js. This is the layer that
// was missing: the frames the holder computes have to be understood by the
// BROWSER's emulator, which is not alacritty and need not agree with it at
// the edges.
const { test, expect } = require("./fixtures");
const h = require("./helpers");

// The alternate screen the holder renders as diffed frames. `less` is the
// nearest thing to a TUI that needs nothing installed.
const READY_TIMEOUT = 15_000;

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

const bufferType = (page) =>
  page.evaluate(() => window.__dalaTerm?.buffer.active.type ?? null);

const ackedBytes = (page) => page.evaluate(() => window.__dalaFlow?.acked ?? 0);

async function terminalReady(page) {
  await expect(page.locator(".xterm").first()).toBeVisible();
  await expect
    .poll(() => ackedBytes(page), { timeout: READY_TIMEOUT })
    .toBeGreaterThan(0);
  await page.evaluate(() => window.__dalaTerm?.focus());
  await expect
    .poll(
      () =>
        page.evaluate(
          () => document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
        ),
      { timeout: READY_TIMEOUT },
    )
    .toBe(true);
}

async function type(page, line) {
  await page.keyboard.type(line);
  await page.keyboard.press("Enter");
}

test.describe("Given 一个把内容画在 alternate screen 上的程序", () => {
  let id;

  test.beforeEach(async ({ page }) => {
    await h.gotoApp(page);
    id = await h.createSession(page, "/tmp");
    await h.selectSession(page, id);
    await terminalReady(page);
  });

  test.afterEach(async ({ page }) => {
    if (id) await h.deleteSession(page, id).catch(() => {});
    id = null;
  });

  test("增量帧被浏览器的 xterm 正确画出来（不是只有服务端自洽）", async ({ page }) => {
    // 一个有形状的画面：不同行、不同列、带颜色，能验出行寻址和 SGR 都没错位。
    await type(
      page,
      "printf '\\033[?1049h\\033[H\\033[2J\\033[2;5HALPHA\\033[4;9H\\033[31mBRAVO\\033[0m\\033[6;3HCHARLIE'",
    );

    await expect.poll(() => bufferType(page), { timeout: READY_TIMEOUT }).toBe("alternate");
    await expect.poll(() => bufferText(page), { timeout: READY_TIMEOUT }).toContain("CHARLIE");

    const rows = (await bufferText(page)).split("\n");
    // 列位置是关键：帧是整行重绘、从第 1 列发出的，如果行内偏移丢了这里就会错。
    expect(rows[1]).toMatch(/^ {4}ALPHA/);
    expect(rows[3]).toMatch(/^ {8}BRAVO/);
    expect(rows[5]).toMatch(/^ {2}CHARLIE/);
  });

  test("反复重绘同一屏：画面对，但字节没跟着涨", async ({ page }) => {
    const before = await ackedBytes(page);

    // 400 次整屏重绘。原始转发要把每一次都送过来；增量帧发现什么都没变，
    // 之后就没话可说了。
    await type(
      page,
      "printf '\\033[?1049h'; for i in $(seq 1 400); do " +
        "printf '\\033[H\\033[2J\\033[3;1HSTEADYFRAME'; done; sleep 0.4",
    );

    await expect.poll(() => bufferType(page), { timeout: READY_TIMEOUT }).toBe("alternate");
    await expect.poll(() => bufferText(page), { timeout: READY_TIMEOUT }).toContain("STEADYFRAME");

    // 让 tick 把最后一帧也发完。
    await page.waitForTimeout(500);
    const spent = (await ackedBytes(page)) - before;

    // 400 次 × 一屏（含 CUP/ED/文本）保守估计也在 10 KB 以上；实测原始转发
    // 是几十 KB。给一个足够宽松但仍然分得开两种模式的上界。
    expect(spent).toBeLessThan(20_000);

    await type(page, "printf '\\033[?1049l'");
    await expect.poll(() => bufferType(page), { timeout: READY_TIMEOUT }).toBe("normal");
  });

  test("进出 alternate screen 不会清掉浏览器的 scrollback", async ({ page }) => {
    // 进 vim 一次就没了历史 —— RIS 会连 scrollback 一起清。
    await type(page, "printf 'MARKERBEFORE\\n'");
    await expect.poll(() => bufferText(page), { timeout: READY_TIMEOUT }).toContain("MARKERBEFORE");

    await type(
      page,
      "printf '\\033[?1049h\\033[H\\033[2JINSIDEALT'; sleep 0.5; printf '\\033[?1049l'",
    );
    // 先等**进去**再等**出来**。只等 "normal" 是个竞态：终端本来就是
    // normal，那条断言在 alt 屏还没建立时就通过了，接着的输入会打在一个
    // 正在切换的屏幕上。
    await expect.poll(() => bufferType(page), { timeout: READY_TIMEOUT }).toBe("alternate");
    await expect.poll(() => bufferType(page), { timeout: READY_TIMEOUT }).toBe("normal");

    await type(page, "printf 'MARKERAFTER\\n'");
    await expect.poll(() => bufferText(page), { timeout: READY_TIMEOUT }).toContain("MARKERAFTER");

    // 进 alt 之前的那一行必须还在。
    expect(await bufferText(page)).toContain("MARKERBEFORE");
  });
});
