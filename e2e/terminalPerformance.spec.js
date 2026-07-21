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
    // Keep the generated scrollback comfortably above the holder's 512 KiB
    // history budget. The retained tail still contains HISTORY-1800, while
    // OLDEST-HISTORY must be clipped from the bounded full repaint.
    await page.keyboard.type(
      `python3 -c "print('OLDEST-HISTORY');[print('HISTORY-%04d-'%i+'x'*90) for i in range(6500)];print('CURRENT-SCREEN')"`,
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

    await page.evaluate((sessionId) => {
      const pane = document.querySelector(`[data-terminal-pane="${sessionId}"]`);
      const root = pane?.querySelector("[data-replay-state]");
      const cover = pane?.querySelector("[data-replay-cover]");
      window.__dalaCoverActivation = [];
      if (!root || !cover) return;

      const sample = (phase) => {
        const style = getComputedStyle(cover);
        window.__dalaCoverActivation.push({
          phase,
          opacity: Number(style.opacity),
          transitionProperty: style.transitionProperty,
        });
      };
      const observer = new MutationObserver(() => {
        if (root.getAttribute("data-replay-state") !== "cover") return;
        sample("mutation");
        requestAnimationFrame(() => sample("first-raf"));
      });
      observer.observe(root, { attributes: true, attributeFilter: ["data-replay-state"] });
      window.__dalaCoverActivationObserver = observer;
    }, ids[0]);

    await page.locator(`[data-terminal-pane="${ids[0]}"] .xterm`).dispatchEvent("wheel", {
      deltaY: -120,
    });
    await expect
      .poll(() => page.evaluate(() => window.__dalaCoverActivation?.length ?? 0), {
        timeout: 5_000,
      })
      .toBeGreaterThanOrEqual(2);
    const coverActivation = await page.evaluate(() => window.__dalaCoverActivation);
    expect(coverActivation.slice(0, 2)).toEqual([
      { phase: "mutation", opacity: 1, transitionProperty: "none" },
      { phase: "first-raf", opacity: 1, transitionProperty: "none" },
    ]);
    await expect.poll(() => bufferText(page), { timeout: 10_000 }).toContain("HISTORY-1800");
    expect(await bufferText(page)).not.toContain("OLDEST-HISTORY");
  });

  test("高 DPR 连续重排后仍完整渲染彩色中英文内容", async ({ page }) => {
    const requireWebgl = process.env.DALA_E2E_WEBGL === "1";
    await h.gotoApp(page);
    ids.push(await h.createSession(page, cwd));
    await expect(page.locator(".xterm").first()).toBeVisible();
    await waitTerminalReady(page);

    const cdp = await page.context().newCDPSession(page);
    try {
      await cdp.send("Emulation.setDeviceMetricsOverride", {
        width: 760,
        height: 620,
        deviceScaleFactor: 3,
        mobile: false,
      });
      const narrowCols = await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.cols ?? 0), { timeout: 10_000 })
        .toBeGreaterThan(0)
        .then(() => page.evaluate(() => window.__dalaTerm?.cols ?? 0));

      await cdp.send("Emulation.setDeviceMetricsOverride", {
        width: 1180,
        height: 760,
        deviceScaleFactor: 3,
        mobile: false,
      });
      await expect
        .poll(() => page.evaluate(() => window.__dalaTerm?.cols ?? 0), { timeout: 10_000 })
        .toBeGreaterThan(narrowCols);

      // ASCII-only shell input emits red SGR text containing exact UTF-8
      // Chinese bytes, so keyboard/IME behavior cannot mask decoder damage.
      await page.keyboard.type(
        "printf '\\033[31mDPR-\\345\\256\\214\\346\\225\\264\\346\\200\\247-" +
          "\\344\\270\\255\\346\\226\\207-ASCII-123\\033[0m\\n'",
      );
      await page.keyboard.press("Enter");
      await expect
        .poll(() => bufferText(page), { timeout: 10_000 })
        .toContain("DPR-完整性-中文-ASCII-123");

      // Inspect xterm's parsed cell attributes in addition to its text. A
      // complete marker with a missing red SGR would indicate emulator/protocol
      // corruption; a red cell with a canvas mismatch points at the renderer.
      const sgr = await page.evaluate(() => {
        const marker = "DPR-完整性-中文-ASCII-123";
        const buffer = window.__dalaTerm?.buffer.active;
        if (!buffer) return null;
        const cell = buffer.getNullCell();

        for (let y = 0; y < buffer.length; y++) {
          const line = buffer.getLine(y);
          const text = line?.translateToString(true) ?? "";
          if (!line || !text.includes(marker)) continue;

          for (let x = 0; x < line.length; x++) {
            line.getCell(x, cell);
            if (cell.getChars() === "D") {
              return {
                fgPalette: cell.isFgPalette(),
                fgColor: cell.getFgColor(),
                fgMode: cell.getFgColorMode(),
                row: y - buffer.viewportY,
                col: x,
                rows: window.__dalaTerm.rows,
                cols: window.__dalaTerm.cols,
                expectedRed: window.__dalaTerm.options.theme?.red ?? null,
                expectedBackground: window.__dalaTerm.options.theme?.background ?? null,
              };
            }
          }
        }
        return null;
      });
      expect(sgr).not.toBeNull();
      expect(sgr.fgPalette).toBe(true);
      expect(sgr.fgColor).toBe(1);

      await expect
        .poll(
          () =>
            page.evaluate(() => {
              const renderer = window.__dalaFlow?.renderer;
              if (!renderer || renderer.kind === "dom") return true;
              const canvas = renderer.canvas;
              return (
                canvas != null &&
                canvas.width === canvas.expectedWidth &&
                canvas.height === canvas.expectedHeight
              );
            }),
          { timeout: 10_000 },
        )
        .toBe(true);

      const renderer = await page.evaluate(() => window.__dalaFlow?.renderer ?? null);
      if (requireWebgl) {
        expect(renderer?.kind).toBe("webgl");
      }
      let screenshotPixels = null;
      if (requireWebgl) {
        // Read the composited frame rather than WebGL's default framebuffer:
        // preserveDrawingBuffer is usually false, so readPixels can be empty
        // even when the user sees a valid glyph grid.
        const screen = page.locator(`[data-terminal-pane="${ids[0]}"] .xterm-screen`);
        const screenshot = await screen.screenshot();
        await test.info().attach("terminal-dpr-canvas", {
          body: screenshot,
          contentType: "image/png",
        });
        screenshotPixels = await page.evaluate(async ({ encoded, markerCell }) => {
          const image = new Image();
          image.src = `data:image/png;base64,${encoded}`;
          await image.decode();
          const canvas = document.createElement("canvas");
          canvas.width = image.width;
          canvas.height = image.height;
          const context = canvas.getContext("2d");
          if (!context) return null;
          context.drawImage(image, 0, 0);
          const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
          const counts = new Map();
          for (let i = 0; i < pixels.length; i += 4) {
            const key = `${pixels[i]},${pixels[i + 1]},${pixels[i + 2]}`;
            counts.set(key, (counts.get(key) ?? 0) + 1);
          }
          const background = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
          if (!background) return { width: canvas.width, height: canvas.height, different: 0 };
          const [br, bg, bb] = background.split(",").map(Number);
          let different = 0;
          let bright = 0;
          for (let i = 0; i < pixels.length; i += 4) {
            const distance =
              Math.abs(pixels[i] - br) +
              Math.abs(pixels[i + 1] - bg) +
              Math.abs(pixels[i + 2] - bb);
            if (distance > 24) different++;
            if (Math.max(pixels[i], pixels[i + 1], pixels[i + 2]) > 96) bright++;
          }

          const parseHex = (value) => {
            const match = /^#([0-9a-f]{6})$/i.exec(value ?? "");
            if (!match) return null;
            const packed = Number.parseInt(match[1], 16);
            return [(packed >> 16) & 0xff, (packed >> 8) & 0xff, packed & 0xff];
          };
          const expectedRed = parseHex(markerCell.expectedRed);
          const expectedBackground = parseHex(markerCell.expectedBackground);
          let redMixPixels = 0;
          let maxRedMix = 0;

          if (
            expectedRed &&
            expectedBackground &&
            markerCell.row >= 0 &&
            markerCell.row < markerCell.rows
          ) {
            // Inspect only the first four ASCII cells of the exact marker row.
            // Antialiased glyph pixels are mixtures of the terminal background
            // and ANSI red, so classify them by projection onto that RGB line
            // instead of looking for one exact palette value.
            const x0 = Math.floor((markerCell.col * canvas.width) / markerCell.cols);
            const x1 = Math.ceil(
              ((markerCell.col + 4) * canvas.width) / markerCell.cols,
            );
            const y0 = Math.floor((markerCell.row * canvas.height) / markerCell.rows);
            const y1 = Math.ceil(
              ((markerCell.row + 1) * canvas.height) / markerCell.rows,
            );
            const vector = expectedRed.map((value, index) => value - expectedBackground[index]);
            const denominator = vector.reduce((sum, value) => sum + value * value, 0);

            for (let y = y0; y < y1; y++) {
              for (let x = x0; x < x1; x++) {
                const offset = (y * canvas.width + x) * 4;
                const color = [pixels[offset], pixels[offset + 1], pixels[offset + 2]];
                const delta = color.map((value, index) => value - expectedBackground[index]);
                const mix = delta.reduce(
                  (sum, value, index) => sum + value * vector[index],
                  0,
                ) / denominator;
                const clamped = Math.max(0, Math.min(1, mix));
                const residual = Math.max(
                  ...color.map((value, index) =>
                    Math.abs(
                      value - (expectedBackground[index] + clamped * vector[index]),
                    ),
                  ),
                );
                if (mix >= 0.2 && residual <= 25) redMixPixels++;
                maxRedMix = Math.max(maxRedMix, mix);
              }
            }
          }

          return {
            width: canvas.width,
            height: canvas.height,
            different,
            bright,
            background,
            redMixPixels,
            maxRedMix,
            expectedRed: markerCell.expectedRed,
            expectedBackground: markerCell.expectedBackground,
          };
        }, { encoded: screenshot.toString("base64"), markerCell: sgr });
        expect(screenshotPixels).not.toBeNull();
        expect(screenshotPixels.different).toBeGreaterThan(100);
        expect(screenshotPixels.bright).toBeGreaterThan(20);
        expect(screenshotPixels.redMixPixels).toBeGreaterThan(20);
        expect(screenshotPixels.maxRedMix).toBeGreaterThan(0.65);
      }
      await test.info().attach("terminal-dpr-renderer-diagnostics", {
        body: JSON.stringify({ renderer, screenshotPixels }, null, 2),
        contentType: "application/json",
      });
    } finally {
      await cdp.send("Emulation.clearDeviceMetricsOverride").catch(() => {});
      await cdp.detach().catch(() => {});
    }
  });

  test("隐藏会话输出超过本地缓冲后，切回来会追到最新当前屏", async ({ page }) => {
    await h.gotoApp(page);
    ids.push(await h.createSession(page, cwd));
    ids.push(await h.createSession(page, cwd));
    await waitTerminalReady(page);

    await page.keyboard.type("printf 'VISIBLE-BEFORE\\n'");
    await page.keyboard.press("Enter");
    await expect.poll(() => bufferText(page), { timeout: 10_000 }).toContain("VISIBLE-BEFORE");
    await page.keyboard.type(
      `python3 -u -c "import time;[print('HIDDEN-%04d-'%i+'x'*80,flush=True) or time.sleep(.002) for i in range(6000)];print('HIDDEN-END-完整性-中文-ASCII-123',flush=True)"`,
    );
    await page.keyboard.press("Enter");
    await h.selectSession(page, ids[1]);
    // Switch back while the producer is still writing. This exercises the
    // warm catch-up path under concurrent live output, rather than only after
    // the hidden command has gone quiet.
    await page.waitForTimeout(4_000);

    // The session had a settled frame before it was hidden. Observe the
    // pooled view while it is revealed again: a warm catch-up must not toggle
    // the opaque cold-attach cover and flash the terminal black.
    await page.evaluate((sessionId) => {
      window.__dalaFrameSamples = [];
      window.__dalaFrameSampling = false;
      window.__dalaRevealAt = null;
      const sample = () => {
        if (!window.__dalaFrameSampling) return;
        const term = window.__dalaTerms?.[sessionId];
        const buffer = term?.buffer.active;
        let nonEmpty = 0;
        if (buffer && term) {
          for (let y = 0; y < term.rows; y++) {
            const line = buffer.getLine(buffer.viewportY + y);
            if ((line?.translateToString(true) ?? "").trim().length > 0) {
              nonEmpty++;
            }
          }
        }
        window.__dalaFrameSamples.push({
          at: performance.now(),
          nonEmpty,
          renderer: window.__dalaFlow?.renderer?.kind ?? null,
        });
        requestAnimationFrame(sample);
      };
      const pane = document.querySelector(`[data-terminal-pane="${sessionId}"]`);
      const root = pane?.querySelector("[data-replay-state]");
      window.__dalaReplayStates = [];
      if (!pane || !root) return;
      const reveal = () => {
        if (window.__dalaRevealAt != null || pane.classList.contains("invisible")) return;
        window.__dalaRevealAt = performance.now();
        window.__dalaFrameSampling = true;
        requestAnimationFrame(sample);
      };
      const revealObserver = new MutationObserver(reveal);
      revealObserver.observe(pane, { attributes: true, attributeFilter: ["class"] });
      window.__dalaRevealObserver = revealObserver;
      reveal();
      const states = window.__dalaReplayStates;
      const observer = new MutationObserver(() => {
        states.push(root.getAttribute("data-replay-state"));
      });
      observer.observe(root, { attributes: true, attributeFilter: ["data-replay-state"] });
      window.__dalaReplayObserver = observer;
    }, ids[0]);
    await expect(page.locator(`[data-terminal-pane="${ids[0]}"]`)).toHaveClass(/invisible/);
    expect(await page.evaluate(() => window.__dalaRevealAt)).toBeNull();

    await h.selectSession(page, ids[0]);
    await expect
      .poll(() => page.evaluate(() => window.__dalaFrameSamples?.length ?? 0), { timeout: 5_000 })
      .toBeGreaterThan(0);
    const firstRevealSample = await page.evaluate(
      () => window.__dalaFrameSamples?.[0] ?? null,
    );
    if (firstRevealSample?.renderer === "webgl") {
      // A Playwright screenshot reads Chromium's composited page, unlike
      // readPixels on WebGL's usually non-preserved default framebuffer.
      const pane = page.locator(`[data-terminal-pane="${ids[0]}"]`);
      const screenshot = await pane.screenshot();
      await test.info().attach("terminal-catch-up-first-reveal-webgl", {
        body: screenshot,
        contentType: "image/png",
      });
      const pixels = await page.evaluate(async (encoded) => {
        const image = new Image();
        image.src = `data:image/png;base64,${encoded}`;
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = image.width;
        canvas.height = image.height;
        const context = canvas.getContext("2d");
        if (!context) return null;
        context.drawImage(image, 0, 0);
        const data = context.getImageData(0, 0, canvas.width, canvas.height).data;
        const counts = new Map();
        for (let i = 0; i < data.length; i += 4) {
          const key = `${data[i]},${data[i + 1]},${data[i + 2]}`;
          counts.set(key, (counts.get(key) ?? 0) + 1);
        }
        const background = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
        if (!background) return null;
        const [red, green, blue] = background.split(",").map(Number);
        let different = 0;
        for (let i = 0; i < data.length; i += 4) {
          const distance =
            Math.abs(data[i] - red) +
            Math.abs(data[i + 1] - green) +
            Math.abs(data[i + 2] - blue);
          if (distance > 24) different++;
        }
        return { width: canvas.width, height: canvas.height, different, background };
      }, screenshot.toString("base64"));
      expect(pixels).not.toBeNull();
      expect(pixels.different).toBeGreaterThan(100);
    }
    await expect
      .poll(
        () =>
          page.evaluate(() =>
            window.__dalaFlow?.replayHistory?.some(
              (replay) => replay.trigger === "catch-up" && replay.presentation === "preserve",
            ),
          ),
        { timeout: 15_000 },
      )
      .toBe(true);
    const catchUpDuration = await expect
      .poll(
        () =>
          page.evaluate(() => {
            const replay = [...(window.__dalaFlow?.replayHistory ?? [])]
              .reverse()
              .find((item) => item.trigger === "catch-up" && item.completedAt != null);
            return replay ? replay.completedAt - replay.startedAt : -1;
          }),
        { timeout: 15_000 },
      )
      .toBeGreaterThan(0)
      .then(() =>
        page.evaluate(() => {
          const replay = [...(window.__dalaFlow?.replayHistory ?? [])]
            .reverse()
            .find((item) => item.trigger === "catch-up" && item.completedAt != null);
          return replay ? replay.completedAt - replay.startedAt : -1;
        }),
      );
    expect(catchUpDuration).toBeLessThan(4_000);
    await expect
      .poll(() => bufferText(page), { timeout: 15_000 })
      .toContain("HIDDEN-END-完整性-中文-ASCII-123");
    const renderer = await page.evaluate(() => window.__dalaFlow?.renderer ?? null);
    expect(renderer).not.toBeNull();
    expect(typeof renderer.contextLosses).toBe("number");
    expect(typeof renderer.canvasMismatches).toBe("number");
    expect(typeof renderer.canvasResizes).toBe("number");
    await test.info().attach("terminal-catch-up-diagnostics", {
      body: JSON.stringify({ catchUpDuration, renderer }, null, 2),
      contentType: "application/json",
    });
    // A context loss is a renderer diagnostic, not proof of protocol damage:
    // the emulator marker above must remain exact even after DOM fallback.
    if (renderer.contextLosses > 0) {
      console.warn("terminal renderer context loss during catch-up", renderer);
    }
    const frameTrace = await page.evaluate(() => {
      window.__dalaReplayObserver?.disconnect();
      window.__dalaRevealObserver?.disconnect();
      window.__dalaFrameSampling = false;
      const replay = [...(window.__dalaFlow?.replayHistory ?? [])]
        .reverse()
        .find((item) => item.trigger === "catch-up" && item.completedAt != null);
      return {
        revealAt: window.__dalaRevealAt ?? null,
        replayCompletedAt: replay?.completedAt ?? null,
        replayStates: window.__dalaReplayStates ?? [],
        samples: window.__dalaFrameSamples ?? [],
      };
    });
    expect(frameTrace.replayStates).not.toContain("cover");
    expect(frameTrace.revealAt).not.toBeNull();
    expect(frameTrace.replayCompletedAt).toBeGreaterThan(frameTrace.revealAt);
    const postRevealSamples = frameTrace.samples.filter(
      (sample) => sample.at >= frameTrace.revealAt,
    );
    expect(postRevealSamples.length).toBeGreaterThan(0);
    expect(postRevealSamples[0].at).toBeGreaterThan(frameTrace.revealAt);
    expect(postRevealSamples[0].nonEmpty).toBeGreaterThan(0);
    expect(postRevealSamples.some((sample) => sample.nonEmpty === 0)).toBe(false);
    await test.info().attach("terminal-catch-up-frame-samples", {
      body: JSON.stringify(frameTrace, null, 2),
      contentType: "application/json",
    });
    const bufferLength = await page.evaluate(() => window.__dalaTerm?.buffer.active.length ?? 0);
    // The producer is intentionally still running when we reveal the view;
    // live output after the screen-only catch-up can legitimately grow the
    // local scrollback again. The exact marker and replay timing above are
    // the integrity/performance assertions, not a fixed buffer length.
    expect(bufferLength).toBeGreaterThan(0);
  });

  test("跨 catch-up 的拆分 ANSI 和 UTF-8 仍保持完整", async ({ page }) => {
    await h.gotoApp(page);
    ids.push(await h.createSession(page, cwd));
    ids.push(await h.createSession(page, cwd));
    await waitTerminalReady(page);

    // Each phase deliberately leaves the holder's parser in a non-ground
    // state while the terminal is hidden. The marker is written only after
    // the incomplete token has reached the PTY, so the test never guesses at
    // a sleep-based boundary. A screen-only catch-up then has to bridge that
    // parser boundary without exposing a partial CSI or replacement glyph.
    const runPhase = async ({ name, body, marker, expected }) => {
      const readyPath = `${cwd}/.split-${name}.ready`;
      const finishPath = `${cwd}/.split-${name}.finish`;
      fs.rmSync(readyPath, { force: true });
      fs.rmSync(finishPath, { force: true });
      // The shell command is wrapped in double quotes. Keep the path literal
      // in single quotes so a temporary directory containing punctuation
      // cannot terminate the Python expression early.
      const pythonReadyPath = readyPath.replaceAll("'", "'\\''");
      const pythonFinishPath = finishPath.replaceAll("'", "'\\''");
      const command =
        `python3 -u -c "import os,time;from pathlib import Path;` +
        `time.sleep(.5);${body};Path('${pythonReadyPath}').touch();` +
        `time.sleep(4.0);${expected.finish};Path('${pythonFinishPath}').touch()"`;

      await page.keyboard.type(command);
      await page.keyboard.press("Enter");
      // Hide before the producer starts. This makes the 180 KiB safe prefix
      // go through HiddenOutputBuffer, rather than being consumed visibly.
      await h.selectSession(page, ids[1]);
      await expect(page.locator(`[data-terminal-pane="${ids[0]}"]`)).toHaveClass(/invisible/);
      await expect.poll(() => fs.existsSync(readyPath), { timeout: 10_000 }).toBe(true);
      // Give the holder a turn after the marker write. The marker is emitted
      // after os.write(ESC/[ or the UTF-8 lead byte), but before the pause;
      // this small margin makes the parser state deterministic on fast hosts.
      await page.waitForTimeout(120);

      const replayCount = await page.evaluate(() => window.__dalaFlow?.replayHistory?.length ?? 0);
      const phaseStart = await page.evaluate(() => performance.now());
      await h.selectSession(page, ids[0]);

      const findPhaseReplay = () =>
        page.evaluate(
          ({ replayCount, phaseStart }) => {
            const history = window.__dalaFlow?.replayHistory ?? [];
            return (
              history
                .slice(replayCount)
                .reverse()
                .find(
                  (replay) =>
                    replay.trigger === "catch-up" &&
                    replay.startedAt >= phaseStart &&
                    replay.presentation === "preserve" &&
                    replay.completedAt != null,
                ) ?? null
            );
          },
          { replayCount, phaseStart },
        );
      await expect.poll(findPhaseReplay, { timeout: 15_000 }).toBeTruthy();
      const phaseReplay = await findPhaseReplay();
      expect(phaseReplay.completedAt).toBeGreaterThan(phaseReplay.startedAt);
      expect(phaseReplay.completedAt - phaseReplay.startedAt).toBeLessThan(4_000);

      // The incomplete token is not part of the holder snapshot. This check
      // runs before the producer's 3 s pause ends and catches a replay that
      // leaked ESC/[ or a lone UTF-8 lead byte into the visible buffer.
      const beforeFinish = await page.evaluate((marker) => {
        const text = (() => {
          const buffer = window.__dalaTerm?.buffer.active;
          if (!buffer) return "";
          const lines = [];
          for (let i = 0; i < buffer.length; i++) {
            lines.push(buffer.getLine(i)?.translateToString(true) ?? "");
          }
          return lines.join("\n");
        })();
        return { text, hasMarker: text.includes(marker), hasReplacement: text.includes("\ufffd") };
      }, marker);
      expect(fs.existsSync(finishPath)).toBe(false);
      expect(beforeFinish.hasMarker).toBe(false);
      expect(beforeFinish.hasReplacement).toBe(false);

      await expect.poll(() => bufferText(page), { timeout: 15_000 }).toContain(expected.text);
      const splitSgr = await page.evaluate((marker) => {
        const buffer = window.__dalaTerm?.buffer.active;
        if (!buffer) return null;
        const cell = buffer.getNullCell();
        for (let y = 0; y < buffer.length; y++) {
          const line = buffer.getLine(y);
          const text = line?.translateToString(true) ?? "";
          if (!line || !text.includes(marker)) continue;
          for (let x = 0; x < line.length; x++) {
            line.getCell(x, cell);
            if (cell.getChars() === "S") {
              return { fgPalette: cell.isFgPalette(), fgColor: cell.getFgColor() };
            }
          }
        }
        return null;
      }, marker);
      expect(splitSgr).not.toBeNull();
      expect(splitSgr.fgPalette).toBe(true);
      expect(splitSgr.fgColor).toBe(1);
    };

    await runPhase({
      name: "ansi",
      body: "os.write(1,b'P'*180000);os.write(1,b'\\033[')",
      marker: "SPLIT-ANSI-ANSI-END",
      expected: {
        text: "SPLIT-ANSI-ANSI-END",
        finish: "os.write(1,b'31mSPLIT-ANSI-ANSI-END\\033[0m\\n')",
      },
    });

    await runPhase({
      name: "utf8",
      body:
        "os.write(1,b'P'*180000);os.write(1,b'\\033[31mSPLIT-UTF8-');" +
        "cjk=bytes([0xe4,0xb8,0xad]);os.write(1,cjk[:1])",
      marker: "SPLIT-UTF8-中-END",
      expected: {
        text: "SPLIT-UTF8-中-END",
        finish: "os.write(1,cjk[1:]);os.write(1,b'-END\\033[0m\\n')",
      },
    });
  });
});
