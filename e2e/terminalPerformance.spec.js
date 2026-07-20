const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const h = require("./helpers");

async function bufferText(page) {
  return page.evaluate(() => {
    const buffer = window.__dalaTerm?.buffer.active;
    if (!buffer) return "";
    const lines = [];
    for (let i = 0; i < buffer.length; i++) {
      lines.push(buffer.getLine(i)?.translateToString(true) ?? "");
    }
    return lines.join("\n");
  });
}

async function waitTerminalReady(page) {
  await expect
    .poll(() => page.evaluate(() => window.__dalaFlow?.acked ?? 0), { timeout: 15_000 })
    .toBeGreaterThan(0);
}

test.describe("Given 用户有很多终端会话", () => {
  let cwd;
  let ids;

  test.beforeEach(async ({ page }) => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-performance-`);
    ids = [];
    await page.addInitScript(() => localStorage.setItem("dala:drawer-open", "0"));
  });

  test.afterEach(async ({ page }) => {
    for (const id of ids) await h.deleteSession(page, id).catch(() => {});
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("桌面的十个会话会逐个预热，切换到第四个和第十个时复用已有终端", async ({
    page,
  }) => {
    await h.gotoApp(page);
    for (let i = 0; i < 10; i++) ids.push(await h.createSession(page, cwd));

    await expect(page.locator("[data-terminal-pane] .xterm")).toHaveCount(10, {
      timeout: 30_000,
    });

    for (const id of [ids[3], ids[9]]) {
      await page.evaluate((sessionId) => {
        const terminal = document.querySelector(`[data-terminal-pane="${sessionId}"] .xterm`);
        terminal.__warmIdentity = sessionId;
      }, id);

      await h.selectSession(page, id);
      await expect(page.locator(`[data-terminal-pane="${id}"]`)).toBeVisible();
      expect(
        await page.evaluate(
          (sessionId) =>
            document.querySelector(`[data-terminal-pane="${sessionId}"] .xterm`)
              ?.__warmIdentity,
          id,
        ),
      ).toBe(id);
    }
  });

  test("冷会话先显示当前屏，用户向上滚动后才载入历史", async ({ page }) => {
    // Prevent background warming in this scenario: selection alone drives
    // the 10-entry MRU so the first session is deterministically evicted.
    await page.addInitScript(() => {
      window.requestIdleCallback = () => 1;
      window.cancelIdleCallback = () => {};
    });
    await h.gotoApp(page);

    ids.push(await h.createSession(page, cwd));
    await expect(page.locator(".xterm").first()).toBeVisible();
    await waitTerminalReady(page);
    await page.keyboard.type(
      `python3 -c "print('OLDEST-HISTORY');[print('HISTORY-%04d-'%i+'x'*90) for i in range(3800)];print('CURRENT-SCREEN')"`,
    );
    await page.keyboard.press("Enter");
    await expect.poll(() => bufferText(page), { timeout: 10_000 }).toContain("CURRENT-SCREEN");

    for (let i = 0; i < 10; i++) ids.push(await h.createSession(page, cwd));
    for (const id of ids.slice(1)) {
      await h.selectSession(page, id);
      await expect(page.locator(`[data-terminal-pane="${id}"]`)).toBeVisible();
    }
    await expect(page.locator(`[data-terminal-pane="${ids[0]}"]`)).toHaveCount(0);

    await h.selectSession(page, ids[0]);
    await expect.poll(() => bufferText(page), { timeout: 10_000 }).toContain("CURRENT-SCREEN");
    expect(await bufferText(page)).not.toContain("HISTORY-1800");

    await page.locator(`[data-terminal-pane="${ids[0]}"] .xterm`).dispatchEvent("wheel", {
      deltaY: -120,
    });
    await expect.poll(() => bufferText(page), { timeout: 10_000 }).toContain("HISTORY-1800");
    expect(await bufferText(page)).not.toContain("OLDEST-HISTORY");
  });

  test("隐藏会话输出超过本地缓冲后，切回来会追到最新当前屏", async ({ page }) => {
    await h.gotoApp(page);
    ids.push(await h.createSession(page, cwd));
    ids.push(await h.createSession(page, cwd));
    await waitTerminalReady(page);

    await page.keyboard.type(
      `python3 -c "import time;time.sleep(.5);[print('HIDDEN-%04d-'%i+'x'*80) for i in range(4000)];print('HIDDEN-END')"`,
    );
    await page.keyboard.press("Enter");
    await h.selectSession(page, ids[1]);
    await page.waitForTimeout(2_000);

    await h.selectSession(page, ids[0]);
    await expect.poll(() => bufferText(page), { timeout: 15_000 }).toContain("HIDDEN-END");
    const bufferLength = await page.evaluate(() => window.__dalaTerm?.buffer.active.length ?? 0);
    expect(bufferLength).toBeLessThan(500);
  });
});
