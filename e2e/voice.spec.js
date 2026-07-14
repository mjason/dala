// 语音 — 配置存服务端（跨设备共享、API Key 只进不出）+ 转写全链路。
//
// 转写链路：浏览器假麦克风录音（--use-fake-device-for-media-stream）→ 前端编码
// WAV → RPC transcribe（不带 endpoint/model/key！）→ Elixir 端从设置行取端点、
// 从项目 dala.jsonc 取 speech.prompt，以 multipart 转发 → 假端点校验 multipart
// 里带 name="prompt" 才返回 PROMPT-OK → 文本落入 composer（CodeMirror，DOM 可读）。
const { test, expect } = require("@playwright/test");
const http = require("node:http");
const fs = require("node:fs");
const h = require("./helpers");

const SEED_JSONC = `{
  // e2e 语音场景种子配置
  "speech": {
    "prompt": "会话涉及 dala 与 Phoenix LiveView，按标准标点转写。"
  }
}
`;

/** 写服务端语音设置（这一行是全实例共享的，未开鉴权时即“全局行”）。 */
async function setSpeechSettings(page, input) {
  const result = await h.rpcRun(page, {
    action: "set_speech_settings",
    input,
    fields: ["endpoint", "model", "apiKeySet"],
  });
  if (!result.success) {
    throw new Error(`set_speech_settings failed: ${JSON.stringify(result.errors)}`);
  }
  return result.data;
}

async function readSpeechSettings(page) {
  const result = await h.rpcRun(page, {
    action: "speech_settings",
    input: {},
    fields: ["endpoint", "model", "apiKeySet"],
  });
  if (!result.success) {
    throw new Error(`speech_settings failed: ${JSON.stringify(result.errors)}`);
  }
  return result.data;
}

/** 设置行在实例内共享 —— 每个用例前后都要归零，否则串场。 */
async function resetSpeechSettings(page) {
  await setSpeechSettings(page, { endpoint: "", model: "", clearApiKey: true });
}

test.describe("Given 一个配置了转写端点与项目提示词的 dala 实例", () => {
  let cwd;
  let sessionId;
  let server;
  let endpoint;

  test.beforeEach(async () => {
    cwd = `/tmp/dala-e2e-voice-${Math.floor(Math.random() * 1e9)}`;
    fs.mkdirSync(cwd, { recursive: true });
    fs.writeFileSync(`${cwd}/dala.jsonc`, SEED_JSONC);

    // 假 whisper：只有 multipart 里带 prompt 字段才回 PROMPT-OK —— 这同时
    // 验证了“服务端从项目 dala.jsonc 读提示词并转发”这一步。
    server = http.createServer((req, res) => {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const body = Buffer.concat(chunks).toString("latin1");
        const hasPrompt = body.includes('name="prompt"');
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ text: hasPrompt ? "PROMPT-OK" : "NO-PROMPT" }));
      });
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    endpoint = `http://127.0.0.1:${server.address().port}/v1`;
  });

  test.afterEach(async ({ page }) => {
    if (sessionId) await h.deleteSession(page, sessionId).catch(() => {});
    sessionId = null;
    await resetSpeechSettings(page).catch(() => {});
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("用户按住语音录 1.5 秒后，转写文本（含项目提示词）出现在 composer", async ({
    page,
  }) => {
    await h.gotoApp(page);
    // 语音配置在服务端：浏览器不再持有 endpoint/model/key。
    await setSpeechSettings(page, { endpoint, model: "whisper-large-v3" });

    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);

    // 语音按钮在 composer 输入条上 —— 先打开 composer。
    await page.keyboard.press("Control+Shift+K");
    const voiceButton = page.locator("#input-bar-voice");
    await expect(voiceButton).toBeVisible();

    // 已验证的流程：点一下开始录音，等 1.5 秒，再点一下停止并转写。
    await voiceButton.click();
    await page.waitForTimeout(1500);
    await voiceButton.click();

    // 转写是异步链路（WAV 编码 + RPC + 服务端转发），轮询 composer 内容。
    await expect(page.locator("#composer-editor .cm-content")).toContainText("PROMPT-OK", {
      timeout: 20_000,
    });
  });

  test("未配置语音服务时点麦克风：出现友好提示，且不会开始录音", async ({ page }) => {
    await h.gotoApp(page);
    await resetSpeechSettings(page);

    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);

    await page.keyboard.press("Control+Shift+K");
    const voiceButton = page.locator("#input-bar-voice");
    await expect(voiceButton).toBeVisible();
    await voiceButton.click();

    // 提示可见（英文默认语言："…endpoint in Settings first"），按钮回到待录状态。
    await expect(page.locator("[data-toast]")).toContainText(/settings/i);
    await expect(voiceButton).toHaveAttribute("data-voice", "idle");
  });

  test("Given 已在一台设备配置了语音服务，另一台设备（全新 context）看到同样的配置", async ({
    page,
    browser,
  }) => {
    // 设备 1：在设置面板里填端点与模型（失焦即存到服务端）。
    await h.gotoApp(page);
    await resetSpeechSettings(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);

    await h.openSettings(page);
    await h.openSettingsTab(page, "voice");
    await page.locator("#speech-endpoint-input").fill(endpoint);
    await page.locator("#speech-endpoint-input").blur();
    await page.locator("#speech-model-input").fill("whisper-cross-device");
    await page.locator("#speech-model-input").blur();
    await expect(page.locator("#speech-settings-status")).toHaveText("✓");

    // 设备 2：全新 browser context —— 独立 localStorage、独立 cookie 罐。
    const second = await browser.newContext();
    const other = await second.newPage();
    try {
      await h.gotoApp(other);
      // 新设备的浏览器存储里没有任何语音配置（连键都还没有）。
      const stored = await other.evaluate(() => localStorage.getItem("dala:speech-prefs"));
      expect(stored ?? "").not.toContain("endpoint");

      await h.selectSession(other, sessionId);
      await h.openSettings(other);
      await h.openSettingsTab(other, "voice");

      await expect(other.locator("#speech-endpoint-input")).toHaveValue(endpoint);
      await expect(other.locator("#speech-model-input")).toHaveValue("whisper-cross-device");
    } finally {
      await second.close();
    }
  });

  test("API Key 只进不出：保存后 DOM 与所有 RPC 响应体里都搜不到明文", async ({ page }) => {
    const secret = "sk-e2e-super-secret-42";

    const bodies = [];
    page.on("response", async (response) => {
      if (!response.url().includes("/rpc/")) return;
      bodies.push(await response.text().catch(() => ""));
    });

    await h.gotoApp(page);
    await resetSpeechSettings(page);
    sessionId = await h.createSession(page, cwd);
    await h.selectSession(page, sessionId);

    await h.openSettings(page);
    await h.openSettingsTab(page, "voice");
    await page.locator("#speech-endpoint-input").fill(endpoint);
    await page.locator("#speech-endpoint-input").blur();
    await page.locator("#speech-api-key-input").fill(secret);
    await page.locator("#speech-api-key-input").blur();

    // 存好之后：输入框清空、占位符表示“已配置”、出现“清除”按钮。
    await expect(page.locator("#speech-api-key-input")).toHaveValue("");
    await expect(page.locator("#speech-api-key-input")).toHaveAttribute(
      "placeholder",
      /••••|configured|已配置/i,
    );
    await expect(page.locator("#speech-api-key-clear")).toBeVisible();

    // 服务端确实存下了（apiKeySet），但读取时永远不回传明文。
    expect(await readSpeechSettings(page)).toMatchObject({ apiKeySet: true });

    // 重开设置面板（重新拉取服务端配置）——DOM 里依然没有明文。
    await page.keyboard.press("Escape");
    await h.openSettings(page);
    await h.openSettingsTab(page, "voice");
    await expect(page.locator("#speech-api-key-input")).toHaveValue("");
    expect(await page.content()).not.toContain(secret);

    // 所有 RPC 响应体里都没有明文（只有请求体里有，那是上行）。
    for (const body of bodies) expect(body).not.toContain(secret);

    // 清除后回到“未配置”，端点不受影响（RPC 编码器把 false 发成 null，取真假即可）。
    await page.locator("#speech-api-key-clear").click();
    await expect(page.locator("#speech-api-key-clear")).toHaveCount(0);
    const cleared = await readSpeechSettings(page);
    expect(Boolean(cleared.apiKeySet)).toBe(false);
    expect(cleared.endpoint).toBe(endpoint);
  });
});
