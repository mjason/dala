// 语音转写 — 用假 whisper 端点做全链路验证：
// 浏览器假麦克风录音（--use-fake-device-for-media-stream）→ 前端编码 WAV →
// RPC transcribe → Elixir 端读取项目 dala.jsonc 的 speech.prompt 并以
// multipart 转发 → 假端点校验 multipart 里带 name="prompt" 才返回 PROMPT-OK
// → 转写文本落入 composer（CodeMirror，DOM 可读）。
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

test.describe("Given 配置了转写端点与项目提示词的用户", () => {
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
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(cwd, { recursive: true, force: true });
  });

  test("用户按住语音录 1.5 秒后，转写文本（含项目提示词）出现在 composer", async ({
    page,
  }) => {
    await h.gotoApp(page);
    // 语音偏好存浏览器本地；每次录音前都会重新读取，页面加载后设置即可。
    await page.evaluate((ep) => {
      localStorage.setItem(
        "dala:speech-prefs",
        JSON.stringify({ endpoint: ep, model: "whisper-large-v3", apiKey: "", micDeviceId: "" }),
      );
    }, endpoint);

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
});
