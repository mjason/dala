// 文件抽屉的实时监控 — 终端命令/agent 在会话目录里建删文件时，抽屉不需要
// 手动刷新就能跟上（服务端 dala_holder watch 递归监视 + 前端就近路由刷新）。
const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const h = require("./helpers");

test.describe("Given 打开文件抽屉的用户", () => {
  let cwd;

  test.beforeEach(() => {
    cwd = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-files-`);
  });

  test.afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("文件抽屉桌面默认打开，关闭后记住偏好", async ({ page }) => {
    let s;
    try {
      await h.gotoApp(page);
      s = await h.createSession(page, cwd);
      await h.selectSession(page, s);
      // 无偏好时桌面默认打开。
      await expect(page.locator("#file-tree")).toBeVisible();
      // 显式关闭 → 刷新后保持关闭。
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toHaveCount(0);
      await page.reload();
      await expect(page.locator("#new-session-button")).toBeVisible();
      await expect(page.locator("#file-tree")).toHaveCount(0);
    } finally {
      if (s) await h.deleteSession(page, s).catch(() => {});
    }
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
      await h.openDrawer(page);
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

  test("文件抽屉：重命名、复制粘贴、剪切粘贴", async ({ page }) => {
    fs.writeFileSync(path.join(cwd, "a.txt"), "hello\n");
    fs.mkdirSync(path.join(cwd, "sub"));

    let s;
    try {
      await h.gotoApp(page);
      s = await h.createSession(page, cwd);
      await h.selectSession(page, s);
      await h.openDrawer(page);
      await expect(page.locator("#file-tree")).toBeVisible();

      // 重命名：右键 → 重命名 → 改名回车。
      const rowA = `[data-path="${path.join(cwd, "a.txt")}"]`;
      await page.click(rowA, { button: "right" });
      await page.click('[data-ctx-item="rename"]');
      const input = page.locator(`[data-rename-entry="${path.join(cwd, "a.txt")}"]`);
      await expect(input).toBeVisible();
      await input.fill("b.txt");
      await input.press("Enter");
      const rowB = `[data-path="${path.join(cwd, "b.txt")}"]`;
      await expect(page.locator(rowB)).toBeVisible();
      await expect(page.locator(rowA)).toHaveCount(0);
      expect(fs.readFileSync(path.join(cwd, "b.txt"), "utf8")).toBe("hello\n");

      // 复制 → 同目录（文件行上粘贴 = 粘到其父目录）：服务端起唯一名。
      await page.click(rowB, { button: "right" });
      await page.click('[data-ctx-item="copy-entry"]');
      await page.click(rowB, { button: "right" });
      await page.click('[data-ctx-item="paste-entry"]');
      await expect(page.locator(`[data-path="${path.join(cwd, "b copy.txt")}"]`)).toBeVisible();

      // 剪切 → 粘进 sub/：目标出现，原位置消失。
      await page.click(rowB, { button: "right" });
      await page.click('[data-ctx-item="cut-entry"]');
      const rowSub = `[data-path="${path.join(cwd, "sub")}"]`;
      await page.click(rowSub, { button: "right" });
      await page.click('[data-ctx-item="paste-entry"]');
      await expect(page.locator(`[data-path="${path.join(cwd, "sub/b.txt")}"]`)).toBeVisible();
      await expect(page.locator(rowB)).toHaveCount(0);
      expect(fs.readFileSync(path.join(cwd, "sub/b.txt"), "utf8")).toBe("hello\n");
    } finally {
      if (s) await h.deleteSession(page, s).catch(() => {});
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
      await h.openDrawer(page);
      // 逐级展开到目标文件所在目录
      for (const dir of ["very", "very/deeply", "very/deeply/nested", "very/deeply/nested/directory", "very/deeply/nested/directory/chain"]) {
        await page.click(`[data-path="${path.join(cwd, dir)}"]`);
      }
      const full = path.join(cwd, deep);
      await page.hover(`[data-path="${full}"]`);

      const tooltip = page.locator("[data-file-path-tooltip]");
      const filename = path.basename(full);
      await expect(tooltip).toBeVisible();
      await expect(tooltip.locator("[data-tooltip-name]")).toHaveText(filename);
      const shownPath = await tooltip.locator("[data-tooltip-path]").textContent();
      expect(shownPath).not.toBe(full); // long directory segments are compacted
      expect(shownPath.endsWith(filename)).toBe(true); // the leaf is never shortened
      expect(await tooltip.evaluate((element) => element.parentElement === document.body)).toBe(true);
      const tooltipBox = await tooltip.boundingBox();
      const viewport = page.viewportSize();
      expect(tooltipBox.x).toBeGreaterThanOrEqual(0);
      expect(tooltipBox.x + tooltipBox.width).toBeLessThanOrEqual(viewport.width);

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
      await h.openDrawer(page);
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

  test("multipart 上传进入文件树和私有附件目录，下载支持 Range 续传", async ({ page }) => {
    const rangePath = path.join(cwd, "range.bin");
    fs.writeFileSync(rangePath, "0123456789");

    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    let managedPath;

    try {
      await h.selectSession(page, id);
      await h.openDrawer(page);

      const drawerUpload = await page.evaluate(async (dir) => {
        const form = new FormData();
        form.append(
          "file",
          new File(["streamed multipart"], "uploaded-from-browser.txt", { type: "text/plain" }),
        );
        form.append("dir", dir);
        const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
        const response = await fetch("/files/upload", {
          method: "POST",
          headers: { Accept: "application/json", "X-CSRF-Token": csrf },
          body: form,
        });
        return { status: response.status, body: await response.text() };
      }, cwd);
      expect(drawerUpload.status).toBe(200);
      const uploadedPath = path.join(cwd, "uploaded-from-browser.txt");
      await page.click("#drawer-refresh-button");
      await expect(page.locator(`[data-path="${uploadedPath}"]`)).toBeVisible();
      expect(fs.readFileSync(uploadedPath, "utf8")).toBe("streamed multipart");

      const attachmentResponse = page.waitForResponse(
        (response) =>
          response.request().method() === "POST" && response.url().endsWith("/files/attachment"),
      );
      await page.locator(".xterm").first().evaluate((terminal) => {
        const transfer = new DataTransfer();
        transfer.items.add(
          new File(["attachment bytes"], "agent note.txt", { type: "text/plain" }),
        );
        terminal.dispatchEvent(
          new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: transfer }),
        );
      });
      const managed = await attachmentResponse;
      expect(managed.status()).toBe(200);
      const managedBody = await managed.json();
      managedPath = managedBody.path;
      expect(path.basename(managedPath)).toBe("agent_note.txt");
      expect(fs.readFileSync(managedPath, "utf8")).toBe("attachment bytes");

      const range = await page.evaluate(async (filePath) => {
        const query = new URLSearchParams({ path: filePath, download: "1" });
        const response = await fetch(`/files/raw?${query}`, { headers: { Range: "bytes=3-6" } });
        return {
          status: response.status,
          contentRange: response.headers.get("content-range"),
          acceptRanges: response.headers.get("accept-ranges"),
          body: await response.text(),
        };
      }, rangePath);
      expect(range).toEqual({
        status: 206,
        contentRange: "bytes 3-6/10",
        acceptRanges: "bytes",
        body: "3456",
      });
    } finally {
      if (managedPath) fs.rmSync(path.dirname(managedPath), { recursive: true, force: true });
      await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("终端附件慢上传显示完整进度并可取消", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    await expect(page.locator(".xterm").first()).toBeVisible();

    let releaseRoute;
    const routeHeld = new Promise((resolve) => {
      releaseRoute = resolve;
    });
    await page.route("**/files/attachment", async (route) => {
      await routeHeld;
      await route.abort("failed").catch(() => {});
    });

    try {
      await page.locator(".xterm").first().evaluate((terminal) => {
        const transfer = new DataTransfer();
        transfer.items.add(
          new File([new Uint8Array(1024 * 1024)], "complete-long-upload-filename-for-agent.bin", {
            type: "application/octet-stream",
          }),
        );
        terminal.dispatchEvent(
          new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: transfer }),
        );
      });

      const progress = page.locator("[data-upload-progress]");
      await expect(progress).toBeVisible();
      await expect(progress).toContainText("complete-long-upload-filename-for-agent.bin");
      await expect(progress).toContainText("0 B / 1.0 MB");
      await expect(progress.locator('[role="progressbar"]')).toHaveAttribute("aria-valuenow", "0");
      const mobileBox = await progress.boundingBox();
      expect(mobileBox.x).toBeGreaterThanOrEqual(0);
      expect(mobileBox.x + mobileBox.width).toBeLessThanOrEqual(390);
      await page.screenshot({ path: "/tmp/dala-upload-progress-mobile.png" });

      await page.setViewportSize({ width: 1280, height: 720 });
      await page.screenshot({ path: "/tmp/dala-upload-progress.png" });

      await progress.locator("[data-cancel-upload]").click();
      releaseRoute();
      await expect(progress).toHaveCount(0);
    } finally {
      releaseRoute?.();
      await page.unroute("**/files/attachment");
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
      await h.openDrawer(page);
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

  test("文件树显示 Git 状态和路径浮层，Git 面板自动跟随外部修改", async ({ page }) => {
    const tracked = path.join(cwd, "tracked.txt");
    fs.writeFileSync(tracked, "original\n");
    execFileSync("git", ["init", "-q", "-b", "main"], { cwd });
    execFileSync("git", ["config", "user.email", "e2e@dala.dev"], { cwd });
    execFileSync("git", ["config", "user.name", "Dala E2E"], { cwd });
    fs.writeFileSync(path.join(cwd, ".gitignore"), "watch-ready.tmp\n");
    execFileSync("git", ["add", "tracked.txt", ".gitignore"], { cwd });
    execFileSync("git", ["commit", "-q", "-m", "initial"], { cwd });

    await h.gotoApp(page);
    const id = await h.createSession(page, cwd);
    try {
      await h.selectSession(page, id);
      await h.openDrawer(page);
      const treeRow = page.locator(`[data-path="${tracked}"]`);
      await expect(treeRow).toBeVisible();
      await expect(treeRow).not.toHaveAttribute("title");
      await treeRow.hover();
      await expect(page.locator("[data-file-path-tooltip] [data-tooltip-name]")).toHaveText(
        "tracked.txt",
      );
      await expect(page.locator("[data-file-path-tooltip] [data-tooltip-path]")).toHaveText(
        tracked,
      );

      // The drawer and watcher channel connect concurrently. Prove the
      // watcher is live with a Git-ignored marker before asserting Git
      // decorations from an external write.
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
      await expect(
        page.locator(`[data-path="${marker}"] [data-git-status="I"]`),
      ).toBeVisible();
      fs.rmSync(marker);
      await expect(page.locator(`[data-path="${marker}"]`)).toHaveCount(0, { timeout: 2000 });

      fs.writeFileSync(tracked, "changed once\n");
      await expect(treeRow.locator('[data-git-status="M"]')).toBeVisible({ timeout: 5000 });

      // Switching tools closes the file drawer and opens Git. Reverting and
      // changing again happen outside the UI: both states must arrive through
      // the watcher without touching the refresh button.
      await page.click("#toggle-git-button");
      await expect(page.locator("#git-panel")).toContainText("tracked.txt");
      execFileSync("git", ["checkout", "--", "tracked.txt"], { cwd });
      await expect(page.locator("#git-panel")).toContainText("Working tree clean", {
        timeout: 5000,
      });

      fs.writeFileSync(tracked, "changed twice\n");
      await expect(page.locator("#git-panel")).toContainText("tracked.txt", { timeout: 5000 });
      await expect(page.locator("#stage-all-button")).toBeVisible();

      execFileSync("git", ["add", "tracked.txt"], { cwd });
      await expect(page.locator("#unstage-all-button")).toBeVisible({ timeout: 5000 });
    } finally {
      await h.deleteSession(page, id).catch(() => {});
    }
  });
});
