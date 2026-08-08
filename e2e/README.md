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
npx playwright test theme.spec.js --update-snapshots # 审核后更新主题视觉基线
```

Playwright 会通过 `start-server.sh` 自动拉起一个 **完全隔离** 的 dala
dev server（127.0.0.1:4499），跑完自动关掉。先确认 4499 没被占用
（`ss -ltnp | grep 4499`，按端口杀，不要按进程名杀）。

也可以从仓库根目录跑 `mix e2e`。

## 每条用例都在盯控制台

所有 spec 从 `./fixtures` 而不是 `@playwright/test` 引入 `test`/`expect`。
那个 fixture 是 `auto` 的：它把 `pageerror` 和 `console.error` 收集起来，
在用例结束时断言为空。

这不是洁癖。React 里一个把整棵子树卸载掉的错误，留下的 DOM 在结构上仍然
是「合理」的 —— 关于布局、文本、几何的断言照样通过，而用户看到的是白屏。
真发生过：一个 `useEffect` 写成裸表达式，把 `scrollTo` 的返回值当成清理
函数，整个设置弹窗卸载，而 `settings.spec.js` 那七条全绿。

某条用例如果是**故意**触发某个错误，屏蔽那一条，而不是关掉检查：

```js
test.use({ ignorePageErrors: [/expected message/] });
```

## 给慢链路写用例

`h.withSocketLatency(page, 300)` 在 socket 上注入单向延迟（用 Playwright
的 `routeWebSocket` 做双向转发代理）。必须在 `gotoApp` **之前**调用。

dala 里所有按延迟分档的策略 —— auto 本地回显、流控的 BDP 水位、holder 的
帧窗口 —— 输入都是实测往返，而 e2e 跑在 localhost（往返 ~1ms）。没有这个
helper 的话，那些策略的慢链路分支一条测试都执行不到。见 `latency.spec.js`。

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
