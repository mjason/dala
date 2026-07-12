# dala e2e 测试套件

BDD 风格的端到端行为测试，基于 `@playwright/test` + 系统 Chromium。
以前靠一次性脚本验证的行为，从现在起都沉淀在这里。

## 运行

```bash
cd e2e
npm install          # 只需一次；不要 npx playwright install（用系统 /usr/bin/chromium）
npx playwright test  # 全量
npx playwright test session.spec.js          # 单个文件
npx playwright test -g "删除会话"             # 按名称过滤
```

Playwright 会通过 `start-server.sh` 自动拉起一个 **完全隔离** 的 dala
dev server（127.0.0.1:4499），跑完自动关掉。先确认 4499 没被占用
（`ss -ltnp | grep 4499`，按端口杀，不要按进程名杀）。

## 隔离机制（重要）

dala 的会话存在 **共享的 sqlite（dala_dev.db）** 里，PTY holder 的
socket 在 **共享的 `$XDG_RUNTIME_DIR/dala-pty`** 里 —— `DALA_DATA_DIR`
如今并不隔离这两样。如果不处理，e2e server 会看到（并可能重连、踢掉）
你真实开发实例的会话和 shell。`start-server.sh` 因此做了三件事：

1. 把 `dala_dev.db` **备份复制** 到 `/tmp/dala-e2e-*` 工作目录，并在
   **副本里** 清空 `terminal_sessions`（绝不动原库）；
2. 用私有 `XDG_RUNTIME_DIR`，e2e 的 holder socket 与真实 shell 完全分开；
3. 由于 dev 配置里数据库路径没有环境变量入口，改用
   `mix run --no-start` + `Application.put_env` 前置注入启动 server
   （不修改任何应用代码/配置）。

启动前还会顺手回收上一轮残留的 e2e holder 进程（只认 socket 在
`/tmp/dala-e2e-*` 下的）和超过 2 小时的旧工作目录。

## 写断言前必读

- **终端内容不在 DOM 里**：终端用 xterm 的 WebGL 渲染，`.xterm` 的
  `textContent` 永远是空的。要断言终端内容，用截图或服务端副作用
  （落盘文件、RPC 状态），**不要** 读 textContent。
- **composer 是 CodeMirror，DOM 可读**：`#composer-editor .cm-content`
  可以直接 `toContainText`。
- 麦克风：全局启动参数带了
  `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`，
  context 授了 `microphone` 权限 —— 假麦克风开箱即用，对其他用例无害。

## 为什么单 worker

所有 spec 打同一个 server，会话是全局服务端状态；并行 worker 会互相
踩到对方的侧栏条目。`workers: 1` + 每个用例自清理（afterEach/finally
删掉自己建的会话）是这套设计的前提，**不要调大**。

## 怎么加场景

1. 新建 `xxx.spec.js`，`test.describe` 写 Given 语境（中文），`test`
   名写用户行为 + 预期（中文）。
2. 用 `helpers.js`：`gotoApp` → `createSession(page, cwd)` →
   `selectSession(page, id)`，设置面板用 `openSettings` /
   `openSettingsTab(page, "voice")`。
3. 会话务必自清理：`afterEach`（或 finally）里
   `deleteSession(page, id).catch(() => {})`；测试用的临时目录放
   `/tmp/dala-e2e-*` 并 `fs.rmSync` 掉。
4. 需要假外部服务（如 whisper 端点）时，直接在 spec 里起 node `http`
   server（参考 `voice.spec.js`），端口用 0 随机分配。
5. 量取布局（如 boundingClientRect）要 **同一帧一次 evaluate 全量测**，
   逐个 `boundingBox()` 会跨到弹窗入场动画的不同帧，出现 1-2px 假偏差。

## 已知坑

- 弹窗有入场动画：布局断言前别急着逐元素测量（见上一条）。
- holder 进程是故意脱离 server 存活的（shell 不随 dala 重启死掉）。
  spec 里删掉会话就会杀掉对应 holder；测试中途崩掉留下的孤儿由
  `start-server.sh` 下次启动时回收。
