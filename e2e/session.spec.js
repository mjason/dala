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

      const ref = `#${id.replaceAll("-", "").slice(0, 6).toUpperCase()}`;
      await expect(page.locator("#active-session-reference")).toHaveText(ref);
      await page.evaluate(() => {
        window.__DALA_CLIPBOARD__ = async (text) => {
          window.__dalaCopiedSessionId = text;
        };
      });
      await page.locator("#active-session-reference").click();
      await expect.poll(() => page.evaluate(() => window.__dalaCopiedSessionId)).toBe(id);

      await h.openSettings(page);
      await expect(page.locator("#session-reference-copy")).toContainText(ref);
      await expect(page.locator("#session-reference-copy")).toContainText(id);
      await page.locator("#session-reference-copy").click();
      await expect.poll(() => page.evaluate(() => window.__dalaCopiedSessionId)).toBe(id);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("滚到中间时开关右侧文件栏,视口守住(reflow 不再跳到别处)", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);

      // 锁定 driver（size owner）。e2e 里偶发 soft-follower（缩放而非 reflow），
      // 那样测不到 reflow 路径；接管刷新把角色钉成 driver 并把焦点还给终端。
      await h.clickTerminalTool(page, "terminal-refit-button");
      await page.waitForTimeout(300);

      // 200 行会随宽度重新折行的长行，每行带唯一标记 LINE-nnn-。
      await page.keyboard.type(
        `python3 -c "print(chr(10).join('LINE-%03d-'%i+'x'*200 for i in range(200)))"`,
      );
      await page.keyboard.press("Enter");
      await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.buffer.active.baseY ?? 0), {
          timeout: 10_000,
        })
        .toBeGreaterThan(80);
      // 让输出与提示符彻底 settle，避免后续 auto-scroll 把视口拉回底部。
      await new Promise((r) => setTimeout(r, 400));

      // 关平滑滚动，让 scrollLines 立即落定（否则读 before 会读到动画中途的
      // 瞬时位置，和 reflow 时抓的锚点对不上）。
      await page.evaluate(() => {
        window.__dalaTerm.options.smoothScrollDuration = 0;
        window.__dalaTerm.scrollLines(-80);
      });
      // 视口顶部所在逻辑行的标记编号（回到折行起点再读）。
      const topLine = () =>
        page.evaluate(() => {
          const b = window.__dalaTerm.buffer.active;
          let row = b.viewportY;
          while (row > 0 && b.getLine(row)?.isWrapped) row--;
          const m = (b.getLine(row)?.translateToString(true) ?? "").match(/LINE-(\d+)-/);
          return m ? Number(m[1]) : -1;
        });
      const cols = () => page.evaluate(() => window.__dalaTerm?.cols ?? 0);
      // 等 viewportY 稳定（scrollLines → DOM scrollTop → ydisp 回填要一帧）再读锚。
      const stableTop = async () => {
        let prev = -1;
        await expect
          .poll(
            async () => {
              const v = await topLine();
              const ok = v >= 0 && v === prev;
              prev = v;
              return ok;
            },
            { timeout: 3_000 },
          )
          .toBe(true);
        return prev;
      };
      const before = await stableTop();
      expect(before, "应停在某条标记行上").toBeGreaterThanOrEqual(0);

      // 开文件栏 → reflow。恢复按顶部逻辑行的文本精确找回、延迟+重试落定，
      // 用 poll 等它稳。内容锚是精确的（旧 bug 是跳 40+ 行）。
      const wide = await cols();
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toBeVisible();
      await expect.poll(cols, { timeout: 5_000 }).toBeLessThan(wide);
      await expect
        .poll(async () => Math.abs((await topLine()) - before), { timeout: 5_000 })
        .toBeLessThanOrEqual(1);

      // 关文件栏 → 再次 reflow → 仍守住。
      const narrow = await cols();
      await page.click("#toggle-drawer-button");
      await expect.poll(cols, { timeout: 5_000 }).toBeGreaterThan(narrow);
      await expect
        .poll(async () => Math.abs((await topLine()) - before), { timeout: 5_000 })
        .toBeLessThanOrEqual(1);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("停在底部关闭文件栏时，SIGWINCH 后重绘的 TUI 仍跟随底部", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);
      await h.clickTerminalTool(page, "terminal-refit-button");

      // Start narrow, then mimic an inline TUI that clears and redraws a long
      // transcript whenever the PTY width changes. Codex does this after the
      // resize itself, so xterm's built-in resize pinning alone is too early.
      const wide = await page.evaluate(() => window.__dalaTerm?.cols ?? 0);
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toBeVisible();
      await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.cols ?? 0), { timeout: 5_000 })
        .toBeLessThan(wide);
      const narrow = await page.evaluate(() => window.__dalaTerm?.cols ?? 0);
      await page.evaluate(() => window.__dalaTerm.focus());
      await page.keyboard.type(
        `python3 -c "import signal,time,sys; d=chr(10).join('REDRAW-%03d-'%i+'x'*100 for i in range(180)); f=lambda *_:(sys.stdout.write(chr(27)+'[2J'+chr(27)+'[H'+d),sys.stdout.flush()); signal.signal(signal.SIGWINCH,f); f(); time.sleep(5)"`,
      );
      await page.keyboard.press("Enter");
      await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.buffer.active.baseY ?? 0), {
          timeout: 10_000,
        })
        .toBeGreaterThan(100);
      await page.evaluate(() => window.__dalaTerm.scrollToBottom());
      await expect
        .poll(() =>
          page.evaluate(() => {
            const b = window.__dalaTerm.buffer.active;
            return b.viewportY === b.baseY;
          }),
        )
        .toBe(true);

      // Closing widens the PTY and triggers the delayed redraw above. Wait
      // past that output, then require the viewport to remain at the bottom.
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toHaveCount(0);
      await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.cols ?? 0), { timeout: 5_000 })
        .toBeGreaterThan(narrow);
      await page.waitForTimeout(500);
      const position = await page.evaluate(() => {
        const b = window.__dalaTerm.buffer.active;
        return { viewportY: b.viewportY, baseY: b.baseY };
      });
      expect(position.viewportY).toBe(position.baseY);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("满屏重复行（TUI 边框）时开关侧栏，视口不跳到顶部", async ({ page }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);
      await h.clickTerminalTool(page, "terminal-refit-button");
      await page.waitForTimeout(300);

      // 260 行「完全相同」的边框。纯文本锚会全命中→落到第一处（顶部）；联合锚
      // 用位置估计消歧，落在原处附近。这正是 codex 这类 TUI 触发的场景。
      await page.keyboard.type(`python3 -c "print(chr(10).join(['-'*180]*260))"`);
      await page.keyboard.press("Enter");
      await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.buffer.active.baseY ?? 0), {
          timeout: 10_000,
        })
        .toBeGreaterThan(120);
      await page.waitForTimeout(400);

      // 位置度量：顶部可见逻辑行「距 buffer 底部的逻辑行数」。内容全相同时读不出
      // 唯一标记，只能用位置——恰好也是「跳到顶部」会暴露的量（会飙到≈总行数）。
      const fromBottom = () =>
        page.evaluate(() => {
          const b = window.__dalaTerm.buffer.active;
          let top = b.viewportY;
          while (top > 0 && b.getLine(top)?.isWrapped) top--;
          let n = 0;
          for (let i = top; i < b.length; i++) if (!b.getLine(i)?.isWrapped) n++;
          return n;
        });
      const cols = () => page.evaluate(() => window.__dalaTerm?.cols ?? 0);

      await page.evaluate(() => {
        window.__dalaTerm.options.smoothScrollDuration = 0;
        window.__dalaTerm.scrollLines(-120);
      });
      let prev = -1;
      await expect
        .poll(
          async () => {
            const v = await fromBottom();
            const ok = v > 0 && v === prev;
            prev = v;
            return ok;
          },
          { timeout: 3_000 },
        )
        .toBe(true);
      const before = prev;
      expect(before, "应滚到回滚中段").toBeGreaterThan(20);

      // 开文件栏 → reflow。旧代码跳顶 → fromBottom 飙到≈总逻辑行数；联合锚守住
      // 原位置（±6 给尾部空行随宽度变化的余量，与「跳顶」的百余行偏差天差地别）。
      const wide = await cols();
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toBeVisible();
      await expect.poll(cols, { timeout: 5_000 }).toBeLessThan(wide);
      await expect
        .poll(async () => Math.abs((await fromBottom()) - before), { timeout: 5_000 })
        .toBeLessThanOrEqual(6);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("视口停在超长折行行的中段时开关侧栏，不跳回行首（保留行内偏移）", async ({
    page,
  }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);
      await h.clickTerminalTool(page, "terminal-refit-button");
      await page.waitForTimeout(300);

      // 20 行普通 + 一条 2400 字符的超长单行（折成很多行）+ 80 行普通。
      await page.keyboard.type(
        `python3 -c "print(chr(10).join('head%02d'%i for i in range(20))); print('X'*2400); print(chr(10).join('tail%02d'%i for i in range(80)))"`,
      );
      await page.keyboard.press("Enter");
      await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.buffer.active.baseY ?? 0), {
          timeout: 10_000,
        })
        .toBeGreaterThan(60);
      await page.waitForTimeout(400);

      // 滚到超长行的正中段（顶部行是折行续行，不是行首）。
      const scrolled = await page.evaluate(() => {
        const b = window.__dalaTerm.buffer.active;
        window.__dalaTerm.options.smoothScrollDuration = 0;
        let start = -1;
        for (let i = 0; i < b.length; i++) {
          const l = b.getLine(i);
          if (l && !l.isWrapped && (l.translateToString(true) || "").startsWith("XXXX")) {
            start = i;
            break;
          }
        }
        if (start < 0) return null;
        let end = start + 1;
        while (end < b.length && b.getLine(end)?.isWrapped) end++;
        window.__dalaTerm.scrollToLine(start + Math.floor((end - start) / 2));
        return { start, end };
      });
      expect(scrolled, "应找到超长行").not.toBeNull();

      // 顶部行确实是折行续行（超长行中段）。
      const topWrapped = () =>
        page.evaluate(() => {
          const b = window.__dalaTerm.buffer.active;
          return b.getLine(b.viewportY)?.isWrapped ?? false;
        });
      await expect.poll(topWrapped, { timeout: 3_000 }).toBe(true);
      const cols = () => page.evaluate(() => window.__dalaTerm?.cols ?? 0);
      const wide = await cols();

      // 开侧栏 → reflow。恢复后顶部行【仍是折行续行】（停在中段）；旧代码丢掉
      // 行内偏移会跳回行首（isWrapped=false）。
      await page.click("#toggle-drawer-button");
      await expect(page.locator("#file-tree")).toBeVisible();
      await expect.poll(cols, { timeout: 5_000 }).toBeLessThan(wide);
      await expect.poll(topWrapped, { timeout: 5_000 }).toBe(true);
    } finally {
      if (id) await h.deleteSession(page, id).catch(() => {});
    }
  });

  test("终端 Ctrl+F 打开查找框，命中显示计数，未命中显示无结果，Esc 关闭并回焦终端", async ({
    page,
  }) => {
    await h.gotoApp(page);
    let id;
    try {
      id = await h.createSession(page, cwd);
      await expect(page.locator(".xterm").first()).toBeVisible();
      await waitTerminalReady(page);

      // 打印可搜索内容（NEEDLEALPHA 会在命令行回显 + echo 输出里多次出现）。
      await page.keyboard.type("echo NEEDLEALPHA NEEDLEBETA NEEDLEALPHA");
      await page.keyboard.press("Enter");
      await expect
        .poll(() =>
          page.evaluate(() => {
            const b = window.__dalaTerm?.buffer.active;
            if (!b) return "";
            let s = "";
            for (let i = 0; i < b.length; i++) s += b.getLine(i)?.translateToString(true) ?? "";
            return s;
          }),
        )
        .toContain("NEEDLEBETA");

      // Ctrl+F 打开查找框，焦点落在输入框（浏览器原生查找被拦截）。
      await page.keyboard.press("Control+f");
      await expect(page.locator("#terminal-find")).toBeVisible();
      await expect(page.locator("#terminal-find-input")).toBeFocused();

      // 命中词 → 出现 “x/y” 计数。
      await page.locator("#terminal-find-input").fill("NEEDLEALPHA");
      await expect
        .poll(async () =>
          /\d+\s*\/\s*\d+/.test(await page.locator("#terminal-find").innerText()) ? "yes" : "no",
        )
        .toBe("yes");

      // 不存在的词 → 无结果提示。
      await page.locator("#terminal-find-input").fill("ZZZ_NOPE_ZZZ");
      await expect(page.locator("#terminal-find")).toContainText("No results");

      // Esc 关闭，焦点回终端。
      await page.locator("#terminal-find-input").press("Escape");
      await expect(page.locator("#terminal-find")).toHaveCount(0);
      await expect
        .poll(() =>
          page.evaluate(
            () => document.activeElement?.classList?.contains("xterm-helper-textarea") ?? false,
          ),
        )
        .toBe(true);
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
      await h.clickTerminalTool(page, "terminal-reset-button");
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
  test("会话按目录自动分组可折叠，Ctrl 多选批量删除", async ({ page }) => {
    const cwdA = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-grp-a-`);
    const cwdB = fs.mkdtempSync(`${os.tmpdir()}/dala-e2e-grp-b-`);
    let s1, s2, s3;
    try {
      await h.gotoApp(page);
      s1 = await h.createSession(page, cwdA);
      s2 = await h.createSession(page, cwdA);
      s3 = await h.createSession(page, cwdB);

      // 同目录的两个会话聚成组：组头显示目录名与数量，可折叠。
      const header = page.locator(`[data-session-group="${cwdA}"]`);
      await expect(header).toBeVisible();
      await expect(header).toContainText("2");
      await header.click();
      await expect(page.locator(`[data-session-row="${s1}"]`)).toBeHidden();
      await header.click();
      await expect(page.locator(`[data-session-row="${s1}"]`)).toBeVisible();

      // Ctrl 点选两行 → 出现多选条 → 批量删除（确认框列出两条）。
      await page.click(`[data-session-row="${s1}"]`, { modifiers: ["Control"] });
      await page.click(`[data-session-row="${s2}"]`, { modifiers: ["Control"] });
      await expect(page.locator("#session-multibar")).toContainText("2");
      await page.click("#delete-selected-button");
      await page.click("#confirm-delete-many-button");
      await expect(page.locator(`[data-session-row="${s1}"]`)).toHaveCount(0);
      await expect(page.locator(`[data-session-row="${s2}"]`)).toHaveCount(0);
      await expect(page.locator(`[data-session-row="${s3}"]`)).toBeVisible();
      s1 = s2 = null;
    } finally {
      for (const id of [s1, s2, s3]) if (id) await h.deleteSession(page, id).catch(() => {});
      fs.rmSync(cwdA, { recursive: true, force: true });
      fs.rmSync(cwdB, { recursive: true, force: true });
    }
  });
});
