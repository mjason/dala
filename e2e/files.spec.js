// 文件抽屉的实时监控 — 终端命令/agent 在会话目录里建删文件时，抽屉不需要
// 手动刷新就能跟上（服务端 dala_holder watch 递归监视 + 前端就近路由刷新）。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const h = require("./helpers");

test.describe("Given 打开文件抽屉的用户", () => {
  let cwd;

  test.beforeEach(() => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-files-`);
  });

  test.afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("展开的目录在切到别的会话再切回后依然展开（不重新 collapse）", async ({ page }) => {
    // 会话 A 的目录里放一个嵌套目录；会话 B 用另一个目录，切过去时抽屉换成
    // 另一棵树。回到 A 时，之前展开的 nested 应当恢复，而不是塌回根。
    fs.mkdirSync(path.join(cwd, "nested"), { recursive: true });
    fs.writeFileSync(path.join(cwd, "nested/inner.txt"), "x\n");
    const cwdB = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-files-b-`);
    fs.writeFileSync(path.join(cwdB, "other.txt"), "y\n");

    let a, b;
    try {
      await h.gotoApp(page);
      a = await h.createSession(page, cwd);
      await h.selectSession(page, a);
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toBeVisible();

      const inner = `[data-path="${path.join(cwd, "nested/inner.txt")}"]`;
      await page.click(`[data-path="${path.join(cwd, "nested")}"]`);
      await expect(page.locator(inner)).toBeVisible();

      // 切到 B：抽屉换成 B 的树，A 里展开的子文件消失。
      b = await h.createSession(page, cwdB);
      await h.selectSession(page, b);
      await expect(page.locator(`[data-path="${path.join(cwdB, "other.txt")}"]`)).toBeVisible();
      await expect(page.locator(inner)).toHaveCount(0);

      // 切回 A：nested 无需再点就仍是展开的。
      await h.selectSession(page, a);
      await expect(page.locator(inner)).toBeVisible();
    } finally {
      // Clean up both sessions so a later spec never inherits a session whose
      // cwd we're about to delete, then remove B's scratch dir.
      if (b) await h.deleteSession(page, b).catch(() => {});
      if (a) await h.deleteSession(page, a).catch(() => {});
      fs.rmSync(cwdB, { recursive: true, force: true });
    }
  });

  test("删除确认框完整显示路径，绝不省略号截断（要删的东西必须看得清）", async ({ page }) => {
    // 曾经用 truncate：路径尾部——恰恰是"这到底是哪个文件"的关键——被切成
    // "…"。现在整条路径换行显示（break-all，路径没有空格可断），高度封顶后
    // 内部滚动。断言看的是渲染文本与真实几何量，不是 class 名。
    const deep = "very/deeply/nested/directory/chain/with_a_long_file_name_indeed.py";
    fs.mkdirSync(path.join(cwd, path.dirname(deep)), { recursive: true });
    fs.writeFileSync(path.join(cwd, deep), "x\n");

    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    await h.selectSession(page, id);
    try {
      await page.click("#toggle-drawer-button");
      // 逐级展开到目标文件所在目录
      for (const dir of ["very", "very/deeply", "very/deeply/nested", "very/deeply/nested/directory", "very/deeply/nested/directory/chain"]) {
        await page.click(`[data-path="${path.join(cwd, dir)}"]`);
      }
      const full = path.join(cwd, deep);
      await page.hover(`[data-path="${full}"]`);
      await page.click(`[data-delete="${full}"]`);

      const shown = page.locator("#delete-target-path");
      await expect(shown).toBeVisible();
      // ① 文本完整：整条绝对路径都在，没有省略号
      await expect(shown).toHaveText(full);
      const text = await shown.textContent();
      expect(text).not.toContain("…");
      // ② 真的渲染出来了（不是被 CSS 裁掉）：多行、且没有横向溢出
      const geom = await shown.evaluate((el) => ({
        scrollW: el.scrollWidth,
        clientW: el.clientWidth,
        lines: Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight)),
      }));
      expect(geom.scrollW).toBeLessThanOrEqual(geom.clientW + 1); // 没被横向裁切
      expect(geom.lines).toBeGreaterThanOrEqual(2); // 长路径确实换了行

      await page.click("#cancel-delete-entry-button");
    } finally {
      await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("大 CSV 使用虚拟表格完整搜索，DOM 只保留可视行", async ({ page }) => {
    const csvPath = path.join(cwd, "large.csv");
    const rows = ["id,name,team"];
    for (let index = 0; index < 1200; index += 1) {
      rows.push(`${index},row-${index},${index % 2 === 0 ? "alpha" : "beta"}`);
    }
    fs.writeFileSync(csvPath, `${rows.join("\n")}\n`);

    await page.setViewportSize({ width: 1200, height: 760 });
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    await h.selectSession(page, id);

    try {
      await page.click("#toggle-drawer-button");
      await page.click(`[data-path="${csvPath}"]`);
      await expect(page.locator("#file-preview table")).toBeVisible();
      await expect(page.locator("#file-preview")).toContainText("1,200 rows");

      // 1,200 records are available to filtering, but virtualization keeps the
      // browser from mounting the whole table at once.
      const mountedRows = await page.locator("#file-preview tbody tr").count();
      expect(mountedRows).toBeGreaterThan(0);
      expect(mountedRows).toBeLessThan(80);

      await page.getByPlaceholder("Search table…").fill("row-1199");
      await expect(page.locator("#file-preview")).toContainText("row-1199");
      await expect(page.locator("#file-preview")).toContainText("1 of 1,200 rows");
    } finally {
      await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("外部建删文件时抽屉自动跟上（含嵌套目录），可见目录 ≤1s", async ({ page }) => {
    fs.writeFileSync(path.join(cwd, "seed.txt"), "seed");
    fs.mkdirSync(path.join(cwd, "nested"));

    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    try {
      await expect(page.locator(".xterm").first()).toBeVisible();
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toBeVisible();
      await expect(page.locator(`[data-path="${cwd}/seed.txt"]`)).toBeVisible();

      // 预热：watch 通道建立与抽屉首次渲染是并行的，反复触碰一个 marker
      // 文件直到它自己出现，证明推送链路已经活了 —— 之后的断言才谈延迟。
      const marker = path.join(cwd, "watch-ready.tmp");
      await expect
        .poll(
          async () => {
            fs.writeFileSync(marker, String(Date.now()));
            return page.locator(`[data-path="${marker}"]`).isVisible();
          },
          { timeout: 15_000, intervals: [300] },
        )
        .toBe(true);

      // 根目录新建 → ≤1s 内出现（Rust 去抖 200ms + 服务端 100ms + 刷新往返）。
      fs.writeFileSync(path.join(cwd, "created-later.txt"), "x");
      await expect(page.locator(`[data-path="${cwd}/created-later.txt"]`)).toBeVisible({
        timeout: 2000,
      });

      // 删除 → 行消失。
      fs.rmSync(path.join(cwd, "created-later.txt"));
      await expect(page.locator(`[data-path="${cwd}/created-later.txt"]`)).toHaveCount(0, {
        timeout: 2000,
      });

      // 展开嵌套目录后，外部往里写 → 同样自动出现（递归监视覆盖全树）。
      await page.click(`[data-path="${cwd}/nested"]`);
      fs.writeFileSync(path.join(cwd, "nested", "inner.txt"), "y");
      await expect(page.locator(`[data-path="${cwd}/nested/inner.txt"]`)).toBeVisible({
        timeout: 2000,
      });
    } finally {
      await h.deleteSession(page, id).catch(() => {});
    }
  });
});
