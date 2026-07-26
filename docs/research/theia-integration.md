# 调研：把 Eclipse Theia 集成进 dala？

**状态**：仅调研，未实施任何产品代码改动
**日期**：2026-07-26
**范围**：Theia（<https://theia-ide.org/>）用于增强 dala 的文本编辑、Git 与整体工作区能力的可行性
**结论（先说）**：**不建议嵌入或反代 Theia**（方案 A/B 判 no-go），建议走**方案 C+D：借协议、借组件、不借外壳** —— 把预算投在 dala 自己的 CM6 编辑器 + 已有 libgit2 面 + 已有 LSP 通道上。下方给出可推翻这个结论的明确条件。

> ⚠️ **同日两次修订，最终结论以 §10 为准**
> - **§9**：用户澄清真实诉求是"沿用我已经熟悉的 VS Code Git 与插件，现有 CM6 保留但只用于移动端" → 命中 §7 翻案条件 1 和 4，改为"不用 Theia，用真 VS Code 的 web 服务端"。
> - **§10（最终）**：用户追加硬约束"**不引入 Node 服务端**" → §9 的 code-server / `code serve-web` 一并出局（它们本质就是 Node 服务）。
>   **最终建议：路线 1 —— dala 生成 `vscode://file/<path>:<line>` 深链，打开你本机那个真 VS Code**（全部插件、真 git UI、零新增服务端，约 1 天）；只有当"必须在 dala 页面里就地编辑"成为强需求时，才评估路线 2（monaco-vscode-api，浏览器内跑真 VS Code 前端，代价是插件只剩 web 那一档）。

---

## 0. 摘要

| 问题 | 回答 |
|---|---|
| 直接嵌入 Theia（同源、同进程页面）？ | **No-go**。Theia 是"应用外壳"而非组件库：Inversify DI + 自有 Shell/Widget 体系，官方文档只讲"基于 Theia 做你自己的产品"，没有"把 Theia 的某个 widget 嵌进别人的 React 应用"这条路。 |
| 作为独立服务反向代理（iframe）？ | **No-go（且与既有决策冲突）**。需要引入 Node 运行时 + Theia 后端（单租户、无内建认证、等价于把宿主机 shell 交出去），而 dala 是自包含 Elixir release；且"iframe + 反代嵌第三方 web UI"在 2026-07-17 已被明确否掉（当时是 agent 工作台方向，改为 dala 自建 UI 直接对接各家官方 server API，见 §6.2）。 |
| 复用/抽取 Theia 的组件与协议？ | **Go（推荐）**。真正值钱的是**协议与规范**（LSP、DAP、SCM 交互模型、OpenVSX 的语法/主题资产格式），dala 已经在 LSP 上这么做了；继续沿这条线，不引入 Theia 运行时。 |
| 不用 Theia 的更轻量路径？ | **Go（推荐主线）**。dala 现有 CodeMirror 6 + libgit2 NIF + LSP WebSocket 桥已覆盖 Theia 净增能力的大部分；缺的是**全文搜索、多文件 rename/refactor UI、editor tabs、stash/rebase/branch graph、调试器**，这些都能在现有架构里增量做，成本远低于引入 Theia。 |

**一句话判据**：dala 的差异化是 *AI-agent 时代的终端工作台*（持久 shell、移动端可用、agent 事件、MCP），不是 IDE。Theia 带来的净增能力里，与这条主线正交的部分（调试器、notebook、VS Code 扩展生态）价值有限；与主线相关的部分（编辑、Git、LSP）dala 已经有了，且**移动端表现优于 Monaco 系**。

---

## 1. dala 现状盘点（本次实际核对代码，非记忆）

### 1.1 架构形状

```
浏览器（React 19 SPA，非 LiveView 页面）
  │  index.tsx → 1.69MB min / 464KB gzip（entry），全量 assets 3.7MB（含 130 个按需 chunk）
  │
  ├── Phoenix Channels（WebSocket，/socket）
  │     terminal:{id} · sessions · settings · agent chat
  ├── Ash Typescript RPC（POST /rpc/run，生成式类型化客户端 ash_rpc.ts）
  ├── GET /lsp/ws（每连接 = 一个语言服务器进程，WebSock 行为）
  ├── GET /files/watch（文件监听，Rust watcher 或 mtime 轮询降级）
  └── GET /files/raw · POST /files/upload（签名 token 或会话 cookie 双门）

Phoenix / Bandit（自包含 Elixir release，内含 ERTS，无 Node 运行时）
  ├── Ash 域：Dala.Terminal（Session/FileSystem/Git/Speech/…）、Dala.Settings、Dala.Accounts
  ├── Dala.Terminal.Server（每会话 GenServer）──unix socket──> dala_holder（Rust，每会话一个守护进程，内嵌 alacritty_terminal）
  ├── Rust NIF：dala_git（libgit2）、dala_theme_renderer
  └── SQLite（会话元数据、用户、主题、设置）
```

关键坐标：`lib/dala_web/lsp_socket.ex`（90 行）、`lib/dala/lsp/discovery.ex`（396 行）、`lib/dala/terminal/file_system.ex`（698 行）、`lib/dala/terminal/git.ex` + `git_ops.ex`（448 行）、`native/dala_git/src/lib.rs`（665 行）、`assets/js/app/cm/lsp.ts`（417 行）。

### 1.2 已有能力（与 Theia 对位的部分）

| 能力 | dala 现状 | 代码坐标 |
|---|---|---|
| 代码编辑 | CodeMirror 6：Lezer 语法（`@codemirror/language-data` 按需 chunk + Elixir/HEEx/JSONC 补充）、搜索、lint、自动完成、自定义主题（与 dala token 同调色板） | `assets/js/app/CodeEditor.tsx`、`cm/languages.ts`、`cm/theme.ts` |
| LSP | **已通** —— 浏览器内 `codemirror-languageserver` 客户端 ⇄ `GET /lsp/ws` ⇄ 每连接一个 stdio 语言服务器；服务器发现走 dala.jsonc/venv/PATH 约定（`Dala.Lsp.Discovery`），带 debug 面板（流量计数、最近消息、诊断快照） | `cm/lsp.ts`、`lsp_socket.ex`、`lsp/debug.ex` |
| 文件树 / 工作区 | 抽屉式文件树（懒加载、虚拟滚动）、fuzzy 快速打开、上传/粘贴落盘、重命名/复制/移动/删除、raw 预览（图片/CSV/xlsx/PDF）、原生文件监听 | `FileDrawer.tsx`（730 行）、`fileDrawer/*`、`file_system.ex` |
| Git | libgit2 NIF：status / diff（工作区+暂存双视角）/ **hunk 级** stage·unstage·discard / **行级** stage·unstage·discard（lazygit 语义）/ commit + amend / log / show / branches / checkout；CM merge view 呈现 | `GitPanel.tsx`、`gitPanel/*`、`LineSelectDiff.tsx`、`patchBuilder.ts`、`git_ops.ex` |
| 终端 | 每会话 Rust holder 守护进程（dtach 模型）+ 内嵌 alacritty_terminal 作权威 emulator；xterm.js WebGL 前端；**shell 跨 dala 重启存活**；OSC 7/9/777 解析（cwd、通知、agent 事件） | `native/dala_holder/`、`terminal/server.ex`、`TerminalView.tsx` |
| 认证 | Ash Authentication（密码策略 + token store），`DALA_AUTH_ENABLED` 开关；文件下载走路径域签名 token；默认绑 127.0.0.1 | `accounts/user.ex`、`plugs/require_auth.ex`、`file_download_token.ex` |
| 扩展面 | dala.jsonc（项目级）+ 设置面板（全局）；MCP endpoint 让 AI 直接驱动设置与终端 | `project_config.ex`、`mcp/*`、`docs/mcp.md` |

### 1.3 确认的缺口（Theia 可能补的）

- **全文搜索**：没有 grep/内容搜索 action（`list_files` 只做文件名枚举供 fuzzy 打开）
- **editor tabs / 多文件同开**：当前是单文件预览，无标签栏、无编辑器分屏
- **跨文件重构**：无 rename symbol / find all references 的 UI（LSP 通道本身具备能力，缺 UI）
- **Git 进阶**：无 stash、interactive rebase、branch graph、cherry-pick、conflict 专用解决 UI（冲突目前只能靠 merge view 手工编辑）
- **调试**：无 DAP，无调试 UI
- **notebook**：无
- **VS Code 扩展生态**：无（且已明确不做 TextMate 语法插件体系，见 §6.3）

---

## 2. Theia 的三种形态与 dala 的适配性

Theia 文档明确区分**平台**与**产品**："You cannot directly launch/use Theia as it is a platform. The project provides one tool called Theia IDE that you can directly download and use."（[docs 首页](https://theia-ide.org/docs/)）许可为 `EPL-2.0 OR GPL-2.0 WITH Classpath-exception-2.0`。

### 2.1 browser + Node 后端（标准云形态）

- **架构**："Theia runs in two separate processes... they communicate through JSON-RPC messages over WebSockets or REST APIs over HTTP"，且 "the backend's express server also serves the code for the frontend"（[Architecture Overview](https://theia-ide.org/docs/architecture/)）。
- **组装**：monorepo + `@theia/cli`；依赖 `@theia/core`、`@theia/editor`、`@theia/filesystem`、`@theia/monaco`、`@theia/navigator`、`@theia/terminal`、`@theia/workspace` 等；`theia build` / `theia start`（默认 3000 端口）；要求 `node >= 18`、`yarn 1.x`；打包器 webpack（默认，将被弃用）或 esbuild（[Composing Applications](https://theia-ide.org/docs/composing_applications/)）。
- **与 dala 的冲突点**：dala 生产环境**没有 Node 运行时**（自包含 ERTS release + Rust 二进制，`install.sh` 只解 tar 到 `~/.local/dala/versions/<tag>`）。引入 Theia 后端 = 发布物里多一个 Node + 一个 npm 应用树，或要求用户自备 Node。
- **适配性**：低。

### 2.2 desktop（Electron）

dala 已有 Electron 客户端（`clients/`，独立 `client-v*` tag），但它是**dala 服务端的壳**，不是本地 IDE。把 Theia 塞进这个壳等于在客户端内跑第二个 IDE，与"服务端持久 shell + 任意端接入"的模型正交。**适配性：不相关**。

### 2.3 browser-only（无后端，静态站点）

- 官方目标：'browser-only' target 生成**无后端**的前端应用，把 Theia 变成静态站点（[Issue #12852](https://github.com/eclipse-theia/theia/issues/12852)、[PR #12853](https://github.com/eclipse-theia/theia/pull/12853)）。
- 支持的包（官方列举）：`@theia/core`、`@theia/filesystem`、`@theia/editor`、`@theia/getting-started`、`@theia/keymaps`、`@theia/markers`、`@theia/monaco`、`@theia/navigator`、`@theia/outline-view`、`@theia/preferences`、`@theia/property-view`、`@theia/userstorage`、`@theia/variable-resolver`。
- **官方明确不可用**：终端/console、**插件与 VS Code web extensions（"the largest missing piece"）**、**源代码管理 / Git**、调试、tasks、**语言服务器**。
- 文件系统走 BrowserFS（OPFS/内存/IndexedDB 皆可自定义，`BrowserFSInitialization` 服务），且 BrowserFS 侧仍有缺口（file watching、目录删除、rename）；Windows 路径在 OPFS 下已知问题（[#17111](https://github.com/eclipse-theia/theia/issues/17111)）。
- **适配性**：这是唯一"能同源塞进 dala 页面"的形态，但**它恰好砍掉了我们唯一想要的三样：Git、LSP、终端**。要补回来 = 自己写 Theia extension 实现 FS provider + 语言客户端 + SCM provider，即"用 Theia 的 DI 体系重写一遍 dala 已有的东西"。

> **关键判断**：Theia 的价值几乎全在"后端 + 插件宿主"那一半。砍掉后端就砍掉了价值；保留后端就要引入 Node 运行时 + 单租户安全模型。**这是本次调研最硬的结构性矛盾。**

---

## 3. 能力增量矩阵：Theia 到底净增什么

| 能力 | Theia（带后端 + vscode 内建扩展） | dala 现状 | 净增 |
|---|---|---|---|
| 代码编辑 | Monaco（VS Code 同源） | CodeMirror 6 | ~0（换引擎不是增能力；且 Monaco **官方不支持移动浏览器**，见 §6.4） |
| 语法高亮 | TextMate 语法（插件） | Lezer（按需 chunk） | 语言覆盖更广，但 dala 已明确**否掉 TextMate 体系**（§6.3） |
| LSP | 通过 vscode 扩展或 Theia 语言客户端 | 已通（自建桥 + 发现逻辑） | ~0 |
| 全文搜索 | `@theia/search-in-workspace`（ripgrep） | **无** | **+** |
| editor tabs / 分屏 | Shell + widget 体系原生 | 无 | **+** |
| 跨文件 rename/references UI | 有 | 无（协议能力已具备） | **+** |
| 文件树/工作区 | `@theia/navigator` + 多根工作区 | 有（单根 + 会话 cwd 跟随） | 多根工作区 **+** |
| Git 基础（status/diff/stage/commit） | vscode.git（SCM API） | 有，且 **hunk/行级** 粒度 | ~0（dala 不落后） |
| Git 进阶（stash/rebase/graph/conflict UI） | 部分（vscode.git 无 graph，需第三方扩展如 GitLens） | 无 | **+（但 Theia 也未必现成）** |
| 终端 | `@theia/terminal`（node-pty） | 有，且**跨重启存活**（holder 模型）+ 移动端优化 | **负**（Theia 的更弱） |
| 调试（DAP） | 有 | 无 | **+** |
| notebook | 有 | 无 | **+** |
| VS Code 扩展生态 | OpenVSX（[Authoring VS Code Extensions](https://theia-ide.org/docs/authoring_vscode_extensions/)） | 无 | **+（生态价值最大项）** |
| AI/agent 集成 | Theia AI / Theia Coder | dala 自建（MCP + agent 事件 + 输入条） | ~0 或负（dala 的更贴合自身模型） |

**净增汇总**：全文搜索、tabs/分屏、跨文件重构 UI、多根工作区、调试、notebook、VS Code 扩展生态。
**其中与 dala 主线相关的**：前四项 —— 而这四项**都不需要 Theia** 也能做（§4 方案 D）。

Git 一项特别说明：Theia 早期自有 `@theia/git`，现在的方向是**弃用它、改用 vscode 内建 git 扩展经 SCM API 提供**（[@theia/vscode-builtin-git 已 deprecated](https://www.npmjs.com/package/@theia/vscode-builtin-git)、[讨论 #15151](https://github.com/eclipse-theia/theia/discussions/15151)）。也就是说：**Theia 侧的 Git 能力上限 ≈ VS Code 的 SCM 面板**，而 dala 的 Git 面板目标是"复制 Fork 的体验"（行级暂存已实现），在这条线上 dala 是**领先方**，不是落后方。

---

## 4. 集成方案

### 方案 A：Theia 作为独立服务 + dala 反向代理（iframe 嵌入）

```
浏览器
 ├── dala SPA（终端/侧栏/agent）           ← 现有
 └── <iframe src="/theia/"> ──┐
                              │  同源，避开 CORS/cookie 问题
Phoenix (Bandit)              │
 ├── plug: require_auth ──────┤  ← 复用 dala 认证做门
 ├── HTTP 反代 /theia/* ──────┼──> localhost:3000  Theia backend (Node ≥18)
 └── WS 反代 /theia/socket ───┘        ├── plugin host 进程（每前端连接一个）
                                       ├── node-pty 终端
                                       └── 文件系统（= dala 的工作区目录）
```

- **依赖/部署**：Node ≥18 运行时 + Theia 应用树（官方 IDE 的 docker 镜像在**数百 MB 量级**，含 Node 与后端 —— 见[社区关于安装体积的讨论](https://community.theia-ide.org/t/can-anything-be-done-to-reduce-theas-installed-size/1400)；具体数字随版本变化，落地前应自行构建一次实测）；dala 发布物从"单 tar + ERTS + 2 个 Rust 二进制"变成"再加一个 Node 应用"，`install.sh`/systemd 单元/自升级流程全部要扩。
- **认证/授权**：Theia **没有内建认证**。社区与维护者的原话：*"There is no built-in 'password-based' nor 'token-based' authentication. Anyone who connects to the exposed port will immediately get full access."*、*"anyone who can access the UI is able to essentially take over the whole underlying machine/container"*（[Discussion #16880](https://github.com/eclipse-theia/theia/discussions/16880)）。维护者说明其设计前提是 **Kubernetes 每用户一 pod + 外层再加认证**。
  → dala 侧必须：`require_auth` 门住 `/theia/*`、Theia 只绑 127.0.0.1、并保证**没有任何旁路**（Theia 自己的端口不能被外部直连）。
- **多租户/工作区隔离**：官方文档只保证"VS Code 扩展按**每个前端连接**跑在隔离进程里"（[Extensions](https://theia-ide.org/docs/extensions/)），维护者对多用户的答案是"K8s 每用户一 pod"（[#16880](https://github.com/eclipse-theia/theia/discussions/16880)）—— 即**后端本身按单租户设计**。推论（需落地验证）：dala 的"多会话、多 cwd、可并行"模型要么 per-workspace 起一个 Theia 后端（进程数 × 内存 ×N），要么强制一个全局工作区（与会话模型脱节）。
- **安全风险**：把"任意代码执行面"从 dala 的受控 RPC/终端扩大到 Theia 的整个后端（tasks、插件、mini-browser 类历史 RCE：[CVE 列表](https://www.cvedetails.com/vulnerability-list/vendor_id-10410/product_id-76702/Eclipse-Theia.html) 记录了 preview/mini-browser 的 RCE 与 DNS-rebinding 读文件）。dala 现有的安全姿态（默认 localhost、MCP token fail-closed、body 限长防未认证 OOM）会被这块新面稀释。
- **工程成本（Elixir 侧）**：dala **没有任何反代代码**，`mint_web_socket` 也不在依赖里。HTTP 反代好写，**WebSocket 反代要自己实现**（WebSock 行为 + Mint.WebSocket 双向泵、背压、超时、断线语义）——这正是我们刚在终端路径上花力气解决的一类问题。或者要求用户前置 nginx，直接违背 dala 的"一个 tar 装完"叙事。Theia 在非根路径 + socket.io 下还有已知回归（[#10853](https://github.com/eclipse-theia/theia/issues/10853)）。
- **UI 集成**：iframe = 两套快捷键系统、两套主题体系、两套滚动/焦点模型；dala 的 leader 键、主题 token、移动端触控条都会在 iframe 边界断裂。
- **取舍**：唯一优点是"能力一次性到位（含调试/notebook/扩展生态）"，代价是运维、安全、UI 一致性、以及与既有架构哲学的三重冲突。

### 方案 B：同源嵌入 browser-only Theia（无 Node 后端）

```
浏览器
 └── dala SPA
      └── Theia browser-only 前端（同页 mount 或 iframe，静态资源由 Phoenix 提供）
           ├── 自写 FileSystemProvider ──> dala RPC（list/read/write/rename/delete）
           ├── 自写语言客户端 ─────────> GET /lsp/ws（现有）
           └── 自写 SCM Provider ──────> dala git_* RPC（现有）
Phoenix：只多一条静态资源路由，后端零新增
```

- **依赖/部署**：**不需要 Node 运行时**（构建期需要，产物是静态资源）→ 这是它相对 A 的最大优势。但构建期引入 yarn 1.x + webpack/esbuild 的 Theia 工具链，与 dala 现有 esbuild 单命令资产流水线并存。
- **能力**：官方 browser-only 明确**不含** Git、LSP、终端、插件、调试 → 三样核心全靠我们自己在 Theia DI 里重写（`FileSystemProvider` + 语言客户端 + `ScmProvider`）。写完之后得到的东西 ≈ 现在的 dala 编辑器 + Theia 外壳（tabs、多根工作区、命令面板）。
- **认证/隔离**：沿用 dala（同源、同 cookie），无新增面 —— 安全上比 A 干净得多。
- **性能/体积**：Theia 前端 + Monaco 的体积是 dala 现有整包（1.69MB min / 464KB gzip entry）的**数倍到一个数量级**（估算，非引用值）；且 Monaco **官方不支持移动浏览器**（§6.4），而 dala 明确投入过移动端终端体验。
- **取舍**：安全/部署可接受，但"净增 = tabs + 命令面板 + 多根工作区"，代价是接住整个 Theia DI 外壳的升级维护 + 移动端退化 + 体积翻倍。**投入产出比差**。

### 方案 C：只借协议与组件，不借外壳（推荐之一）

不引入任何 Theia 运行时，只把 Theia/VS Code 生态里**已经标准化的部分**继续吸收进 dala 自己的实现：

```
dala SPA（唯一外壳，React + CM6）
 ├── LSP：已通（GET /lsp/ws）→ 增量把协议面做全：
 │      rename symbol / references / code actions / formatting / semantic tokens
 ├── DAP（若将来要调试）：同一套"每连接一个子进程"的桥模式，换协议即可
 ├── SCM 交互模型：借 VS Code/Fork 的**交互语义**（已在做：hunk/行级暂存）
 └── 资产格式：主题/图标等按需借用社区格式（TextMate 语法已否，见 §6.3）
```

- **依赖**：零新增运行时依赖。
- **成本**：每项能力独立可交付、可回滚，测试沿用现有 TDD/BDD 分层（vitest 纯函数 + ExUnit + Playwright）。
- **风险**：低。最大风险是"自己写 UI 的工作量"，但这正是 dala 已经证明能做的部分（Git 面板、行级暂存、LSP 桥都是自建）。

### 方案 D：不用 Theia 的更轻量替代路径（推荐主线）

按"净增能力"逐项给最省的实现路径：

| 缺口 | 最省路径 | 依赖 | 备注 |
|---|---|---|---|
| 全文搜索 | 后端加 `search_content` action：优先 `rg --json`（有则用），否则 Elixir 流式扫描；前端结果面板复用现有虚拟列表 | 无新前端依赖 | 与 `list_files` 同一套 gitignore/限流逻辑 |
| editor tabs / 多文件 | 前端状态层加"打开文件栈"，复用现有 `CodeEditor`；CM6 天然多实例 | 无 | 纯前端，可 vitest 覆盖 |
| 跨文件 rename / references | LSP 通道已具备：加 `textDocument/rename`、`references` 调用 + 结果面板 + 多文件写回（走现有 `write_file`） | 无 | 需要"预览 + 应用"两阶段 UI |
| 多根工作区 | 会话已带 cwd；把抽屉从"单根"扩成"根列表" | 无 | |
| Git stash / rebase / graph / conflict UI | libgit2 NIF 已在手（`native/dala_git`）：stash/cherry-pick/rebase 都是 git2 API；graph 是提交图布局算法（纯前端可测） | 无 | 与 Git 面板既定的 next stages（stash / interactive rebase / branch graph）一致 |
| 调试（DAP） | 复用 `lsp_socket.ex` 的桥模式起 debug adapter；前端做断点/变量/调用栈面板 | 无新后端依赖 | 工作量最大的一项，且是"是否真需要"的产品问题 |
| VS Code 扩展生态 | **不做**（结构性不兼容：需要插件宿主 + VS Code API 面） | — | 想要生态就必须回到方案 A |
| Monaco 换引擎 | **不做**（移动端不支持 + 体积 + 与现有 CM6 投资冲突） | — | 若某天必须要 Monaco 生态，[monaco-languageclient](https://github.com/TypeFox/monaco-languageclient) + `@codingame/monaco-vscode-api` 是不引入 Theia 的最短路径（版本与 VS Code 强耦合，是长期维护税） |

---

## 5. 横向对比

| 维度 | A 反代 Theia | B browser-only 内嵌 | C 借协议/组件 | D 自建轻量路径 |
|---|---|---|---|---|
| 新增运行时依赖 | Node ≥18 + Theia 树 | 无（仅构建期） | 无 | 无 |
| 发布/安装复杂度 | 高（发布物结构改变） | 中（资产流水线并存） | 无变化 | 无变化 |
| 认证/多租户 | 需自建门 + 单租户后端矛盾 | 沿用 dala | 沿用 dala | 沿用 dala |
| 新增攻击面 | 大（后端/插件/tasks） | 小 | 无 | 无 |
| 移动端 | Monaco 不支持 | Monaco 不支持 | 保持 CM6 | 保持 CM6 |
| UI 一致性 | 差（iframe 双系统） | 中（Theia 外壳） | 好 | 好 |
| 净增能力 | 最大（含调试/notebook/扩展生态） | 小（tabs/命令面板/多根） | 中 | 中（按需逐项） |
| 可回滚性 | 差 | 中 | 好（逐项） | 好（逐项） |
| 维护税 | 高（跟 Theia 版本） | 高（跟 Theia DI 版本） | 低 | 低 |
| 与既有决策冲突 | **是**（iframe 反代已被否；"不是拿来做编辑器的"） | 部分 | 否 | 否 |

---

## 6. 硬约束与既有决策（决策前必须知道的）

### 6.1 无 Node 运行时的发布模型
dala 通过 GitHub Actions 云编译成自包含 tar（ERTS + `dala_holder`/`dala_git`/`dala_theme_renderer`），`install.sh` 解包到 `~/.local/dala/versions/<tag>` + systemd/launchd 守护 + 应用内自升级。任何"需要 Node 后端常驻"的方案都要改动这条链路的每一环。

### 6.2 iframe + 反代嵌第三方 web UI 已被否
2026-07-17，在 agent 工作台方向上，用户明确要求"**不嵌官方/第三方 web UI（iframe+反代方案被否）**"，改为 dala 自建 UI 接官方 server API。Theia 方案 A 与此**同形**，除非用户主动推翻这条原则，否则应视为 no-go。

### 6.3 "我们不是拿来做编辑器的"
2026-07-18，TextMate 语法插件体系（引擎 + 上传 UI + 后端 resolver + onig.wasm）在实现完成后被整体移除，用户判词："意义不大，我们不是拿来做编辑器的"。这是**关于产品边界的直接信号**：把 dala 往 IDE 方向推的大型投入需要用户明确改口。

### 6.4 移动端：Monaco 官方不支持
Monaco 官方 FAQ 对"是否支持移动浏览器"的回答是 **"No."**（[monaco-editor](https://github.com/microsoft/monaco-editor)），社区补丁（[PR #4623](https://github.com/microsoft/monaco-editor/pull/4623)、[Issue #1504](https://github.com/microsoft/monaco-editor/issues/1504)）不是官方支持。dala 已在移动端终端上做过专门投入（尺寸所有权模型、触控键条、iOS 16px 规避），编辑器退化到"移动端不可用"是产品级倒退。CodeMirror 6 是当前公认的移动端可用选项。

### 6.5 许可
Theia 是 `EPL-2.0 OR GPL-2.0 WITH Classpath-exception-2.0`，dala 是 MIT。以 EPL-2.0 分支组合、且不修改 EPL 源文件时，通常可与 MIT 应用共存（EPL 是文件级弱著佐权），但**分发修改过的 EPL 文件需保持 EPL**。若走方案 A/B 需要法务确认，本报告不构成法律意见。

### 6.6 LSP 扩展哲学
2026-07-12 已定：LSP 走"用户/agent 显式配置（dala.jsonc）"，不做自动下载/环境探测魔法。Theia/VS Code 生态的扩展安装模型（OpenVSX 运行时装扩展）与这条哲学正相反。

---

## 7. 推荐路线（分阶段、可验证）

**总方针**：C + D。不引入 Theia 运行时；按"用户实际抱怨顺序"逐项补齐工作区能力，每阶段独立可交付、可回滚，沿用现有测试分层（vitest 纯函数 → ExUnit → Playwright BDD）。

### Phase 0：定边界（0.5 天，无代码）
- 产出：一句话产品边界确认 —— dala 的编辑/Git 面**服务于 agent 工作流**，不追求 IDE 完备性。
- **Go 条件**：用户确认边界（或明确推翻 §6.3，那就直接走本节末的「何时重新评估 Theia」重算）。

### Phase 1：全文搜索（1-2 天）
- 后端 `search_content`（rg 优先、Elixir 流式兜底、gitignore 尊重、结果与耗时双限流）；前端结果面板 + 跳转定位。
- **验收**：ExUnit（限流/超时/二进制跳过/gitignore）、Playwright（搜索→点击→编辑器定位到行）。
- **Go/No-go**：若在 dala 自身仓库（约 1.5 万行 lib + 前端）上 P95 < 300ms 且不拖垮会话进程 → 继续。

### Phase 2：editor tabs + 多根工作区（2-3 天）
- 打开文件栈（MRU、脏标记、关闭确认）；抽屉支持多根。
- **验收**：vitest（tab 状态机纯函数）、Playwright（多文件切换保留光标/滚动位置）。

### Phase 3：LSP 深化 —— rename / references / code actions（3-5 天）
- 复用现有 `/lsp/ws`；两阶段 UI（预览变更集 → 应用），写回走 `write_file`（保留 dala 的写入限额与冲突检测）。
- **验收**：至少两种语言真机验证（Elixir + Python）；ExUnit 覆盖多文件写回的原子性（部分失败必须可回滚）。
- **Go/No-go**：若跨文件写回无法做到"要么全成要么全不动" → 停在只读能力（references/hover）。

### Phase 4：Git 进阶（stash → conflict UI → graph）（5-8 天，可拆）
- 顺序按价值：stash（libgit2 直接支持）→ 冲突解决 UI（现有 merge view + `ours/theirs/both` 动作）→ branch graph（提交图布局纯函数，易测）。
- **验收**：git NIF 层 ExUnit + Playwright 全链路（造冲突 → 解决 → 提交）。

### Phase 5（可选，需产品决策）：调试（DAP）
- **只有在用户明确要"在 dala 里断点调试"时才启动**。届时重新评估：自建 DAP 桥（沿用 LSP 桥模式）vs 回到方案 A。
- **Go 条件**：有真实使用场景 + 愿意承担一个新协议面的长期维护。

### 何时重新评估 Theia（明确的 flip 条件）

出现**任一**条时，本报告的结论应重新计算：

1. **要 VS Code 扩展生态**：产品目标变成"用户能装 OpenVSX 扩展" → 只有方案 A 能给，届时接受 Node 运行时 + 单租户安全模型。
2. **要托管多租户产品**：dala 从自托管工具变成多用户云服务 → 已经需要 K8s/编排层，Theia Cloud（[theia-cloud.io](https://theia-cloud.io/)）的每用户 pod 模型反而变成加分项而非负担。
3. **调试 + notebook 同时成为一等目标**：两个大协议面同时要做，自建成本开始接近引入成本。
4. **移动端不再是目标**：若明确放弃移动端编辑体验，Monaco/Theia 的最大硬伤消失。
5. **上游变化**：Theia browser-only 目标补齐插件/LSP/SCM（跟踪 [#12852](https://github.com/eclipse-theia/theia/issues/12852)）→ 方案 B 的性价比会显著改善。

**No-go 保持条件**（当前全部成立）：无 Node 运行时的发布模型 + 移动端是目标 + iframe 反代已被否 + "不是拿来做编辑器的" + Git/LSP/终端三项 dala 已不落后。

---

## 8. 参考链接（均已核对）

Theia 官方
- [Theia 文档首页（平台 vs 产品、许可）](https://theia-ide.org/docs/)
- [Architecture Overview（前后端两进程、JSON-RPC over WebSocket、后端 express 同时服务前端）](https://theia-ide.org/docs/architecture/)
- [Composing Applications（@theia/cli、包清单、node>=18、webpack/esbuild）](https://theia-ide.org/docs/composing_applications/)
- [Extensions（Theia extension vs VS Code extension、插件按前端连接隔离进程、OpenVSX）](https://theia-ide.org/docs/extensions/)
- [Authoring VS Code Extensions](https://theia-ide.org/docs/authoring_vscode_extensions/)
- [Theia Cloud（K8s 每用户 pod 的多租户框架）](https://theia-cloud.io/)

Theia 源码/议题
- [Issue #12852 — Browser-Only: Run Theia without a backend（支持包清单 + 明确缺失项）](https://github.com/eclipse-theia/theia/issues/12852)
- [PR #12853 — Support 'browser-only' Theia](https://github.com/eclipse-theia/theia/pull/12853)
- [Issue #17111 — browser-only OPFS 在 Windows 路径下失败](https://github.com/eclipse-theia/theia/issues/17111)
- [Discussion #16880 — "Dangerous Theia IDE Docker browser application"（无内建认证、可接管整机、维护者说明 K8s 前提）](https://github.com/eclipse-theia/theia/discussions/16880)
- [Issue #10853 — socket.io 破坏反代 + 非根 URL](https://github.com/eclipse-theia/theia/issues/10853)
- [Discussion #15151 — @theia/git 的弃用方向](https://github.com/eclipse-theia/theia/discussions/15151)
- [@theia/vscode-builtin-git（npm，已 deprecated）](https://www.npmjs.com/package/@theia/vscode-builtin-git)
- [git-scm-provider.ts（Theia 自有 git 的 SCM 实现，历史包）](https://github.com/eclipse-theia/theia/blob/master/packages/git/src/browser/git-scm-provider.ts)
- [Eclipse Theia CVE 列表（preview/mini-browser RCE、DNS-rebinding 读文件）](https://www.cvedetails.com/vulnerability-list/vendor_id-10410/product_id-76702/Eclipse-Theia.html)
- [社区帖：能否缩小 Theia 安装体积（含镜像体积讨论）](https://community.theia-ide.org/t/can-anything-be-done-to-reduce-theas-installed-size/1400)

生态/替代
- [EclipseSource: Eclipse Theia in Practice（2026-07，落地经验：DI/RPC/性能陷阱、安装与更新交付需自理）](https://eclipsesource.com/blogs/2026/07/02/eclipse-theia-in-practice-getting-started-lessons-from-the-field/)
- [monaco-languageclient（不引入 Theia 的 Monaco+LSP 路径，与 @codingame/monaco-vscode-api 版本强耦合）](https://github.com/TypeFox/monaco-languageclient)
- [monaco-editor（官方 FAQ：移动浏览器 "No."）](https://github.com/microsoft/monaco-editor)
- [monaco-editor Issue #1504 — mobile (touch) support 请求](https://github.com/microsoft/monaco-editor/issues/1504)
- [openvscode-server（连接 token 是唯一内建"认证"，默认无保护）](https://github.com/gitpod-io/openvscode-server)

dala 内部参照
- `docs/mcp.md`（MCP 面）、`README.md` 的「项目配置：dala.jsonc」「目录跟随」两节
- 代码坐标见本文 §1

---

## 9. 修订（2026-07-26，同日）：当目标是"直接用 VS Code 的 Git 和插件"

用户澄清了真实动机：**不是要更多 IDE 功能，而是要沿用自己已经熟练的 VS Code 交互和插件生态**；现有 CM6 一套**保留但只服务移动端**。

这同时命中了 §7「何时重新评估」里的第 1 条（要 VS Code 扩展生态）和第 4 条（移动端不再是该surface的约束）。**§0 的结论对这个新前提不再适用**，本节给出修订版。

> 关于 §6.2 的先例：2026-07-17 否掉 iframe+反代，是在"我们想要自己的 agent UI，不该去包别人的"这个语境下。这次相反 —— **用户要的就是那个第三方 UI 本身**，先例不自动适用，但它的技术代价（双快捷键系统、双主题、WS 反代工程量）依然成立，需要显式接受。

### 9.1 关键分叉：插件市场决定选型（先回答这个再谈架构）

| 你要装的插件 | 唯一可行方案 | 说明 |
|---|---|---|
| **Microsoft 专有**：Copilot / Copilot Chat、Pylance、C# Dev Kit、C/C++、Remote-*、Live Share | **官方 `code serve-web`**（VS Code Server） | 微软 Marketplace 的服务条款只允许微软自家产品访问；code-server / openvscode-server / Theia **在法律上不能连微软市场**（[Gitpod 说明](https://www.gitpod.io/docs/enterprise/references/ides-and-editors/vscode-extensions)、[Copilot 上架 OpenVSX 的长期请求](https://github.com/orgs/community/discussions/58566)） |
| **Open VSX 上有的**（GitLens、各语言基础插件、主题、Vim 键位…） | **code-server** 或 **openvscode-server**（也可 Theia） | 默认市场即 Open VSX |
| 只要**内建 Git UI**（SCM 面板、diff、stage、冲突解决） | 任意一条都够 | 内建 git 扩展在三者中都自带 |

**重要许可约束**：VS Code Server（`code serve-web` / `code tunnel` 背后的东西）是微软专有产品，官方文档明确 *"hosting it as a service is not allowed, as specified in the VS Code Server license"*（[VS Code Server 文档](https://code.visualstudio.com/docs/remote/vscode-server)）。
→ **你自己在自己机器上自用** = 正常使用场景；**把"dala 自动托管 VS Code Server"作为发布功能给别人用** = 需要法务确认，很可能不允许。这决定了实现姿态：dala 应当**发现/连接用户自己装的 VS Code**，而不是替用户分发和托管它。

### 9.2 三条落地路径

#### A1：外部真 VS Code + dala 只做入口（**成本最低，推荐先做**）

```
dala SPA（终端/会话/agent/移动端 CM6）
 └── 「在 VS Code 中打开」按钮/leader 键
      └── window.open("http://127.0.0.1:8080/?folder=<session.cwd>")   ← 新标签页/新窗口
                                   │
                        用户自己起的 code-server 或 `code serve-web`
                        （dala 只负责发现它在跑 + 拼 URL）
```

- **dala 改动面**：一个设置项（VS Code Web 的 URL/端口）+ 每个会话一个"在 VS Code 打开"动作（拼 `?folder=<cwd>`，待实测该 query 参数在目标版本的行为）+ 可选的健康探测。**几百行以内，无新依赖，无反代。**
- **认证**：完全交给 code-server 自己（`--auth password`）或 `--connection-token`；dala 不引入新的暴露面。
- **UI**：两个标签页，不共享快捷键/主题。对"编辑归 VS Code、终端归 dala"的分工其实很自然。
- **风险**：几乎为零，可随时撤回。

#### A2：同源 iframe + dala 反向代理（**沉浸式，但工程量真实**）

```
浏览器
 ├── dala SPA 外壳（侧栏/终端/agent 保持不变）
 └── 编辑区 <iframe src="/vscode/?folder=…">
Phoenix
 ├── plug require_auth 门住 /vscode/*        ← 复用 dala 登录态
 ├── HTTP 反代 ─────────────┐
 └── WS 反代（需自写）───────┼──> 127.0.0.1:8080  code-server（自带 node，--auth none 但只绑 lo）
                            └──> 注入 connection token / cookie
```

- **必须自己写 WebSocket 反代**（dala 目前零反代代码，`mint_web_socket` 不在依赖里）。这是本方案的主要工程量与主要风险点。
- **子路径**：code-server 有 `--abs-proxy-base-path` 等能力（[guide.md](https://github.com/coder/code-server/blob/main/docs/guide.md)）；官方 `serve-web` 的子路径支持仍需自行用 `code serve-web --help` 核实（社区 issue [microsoft/vscode#192947](https://github.com/microsoft/vscode/issues/192947) 未见明确落地结论）。**先验证再动手。**
- **安全**：code-server 官方原话 *"Never expose code-server directly to the internet without some form of authentication and encryption, otherwise someone can take over your machine via the terminal."* → 上游只绑 127.0.0.1，唯一入口是 dala 的认证门，且必须确保没有旁路。
- **收益**：单页体验、共享登录态、可以把 VS Code 当成 dala 的一个 pane 与终端并排。

#### A3：monaco-vscode-api 深度内嵌（**最贴合 dala 外壳，但最重**）

[@codingame/monaco-vscode-api](https://github.com/CodinGame/monaco-vscode-api) 把 VS Code 的真实服务实现塞进你自己的页面：可加载 `.vsix`、有 **webworker 扩展宿主**（在 iframe 里的 worker 跑扩展），也支持连远端 VS Code Server 跑 node 扩展。
但：`initialize` 只能调用一次且必须在建第一个 editor 前；**构建仅支持 Linux/Mac**；与 VS Code/Monaco 版本强耦合（当前对齐 vscode 1.129.x）；SCM/git 视图是否开箱可用需要实测。
→ 适合"要把 VS Code 组件拼进 dala 自己的布局"，不适合"我要我熟悉的那个完整 VS Code"。**与用户诉求不完全匹配，列为备选。**

### 9.3 dala 侧要做的事（多数机制已存在）

| 需求 | 复用什么 | 备注 |
|---|---|---|
| 发现/托管 VS Code 服务端 | `Dala.Updater` 已经会下载+解压 GitHub release tarball；`DynamicSupervisor + Registry` 已是 holder 的监督模型 | **建议只"发现+连接"，不替用户分发**（§9.1 许可） |
| 认证门 | `DalaWeb.Plugs.RequireAuth`（A2 用） | A1 不需要 |
| 会话 ↔ 工作区映射 | 会话已带 `cwd`，OSC 7/轮询已在跟随 | 拼 `?folder=<cwd>`；多项目 = 多标签页，无需多实例 |
| 桌面/移动分流 | `useCoarsePointer()` 已有（`TouchKeyBar.tsx`） | 桌面 → VS Code 入口；移动 → 现有 CM6 |
| 终端 | **不迁移**：dala 的 holder 模型（跨重启存活、OSC 777 agent 事件、移动端优化）优于 code-server 内建终端 | VS Code 侧可让用户自行关掉终端面板 |

### 9.4 现有 CM6 栈怎么定位（不浪费已有投资）

保留，并明确降级为三个场景：**① 移动端全部编辑**；**② 桌面端的轻量预览/快速改**（点文件树即看，不必唤起 VS Code）；**③ diff/冲突浮层**（已有 merge view + 行级暂存，和 VS Code 的 SCM 并存不冲突 —— 用哪个由用户当下在哪个界面决定）。
代价是**两套 Git UI 并存**：可接受（它们操作的是同一个 .git，libgit2 与 git 命令行语义一致），但要注意**同时打开两边时的状态刷新**（dala 侧已有文件监听，git 状态变化可触发刷新；需实测 VS Code 写 index 后 dala 面板是否及时更新）。

### 9.5 修订后的推荐路线

**Phase A（30 分钟，纯手工，无代码）** —— 先确认手感和许可路线：
1. 手动起一个：`code serve-web --port 8080 --connection-token <secret> --accept-server-license-terms`（要 MS 市场）或下载 code-server standalone tarball（自带 node，要 Open VSX）。
2. 浏览器打开 `?folder=<某个项目>`，装 1-2 个你日常用的插件，用它的 SCM 面板做一次真实提交。
3. **Go/No-go**：插件是否都在（MS 专有 vs Open VSX）、git 手感是否就是你要的、机器负载是否可接受。**这一步不通过，后面全不用做。**

**Phase B（1 天）** —— 落 A1：设置项 + 会话级"在 VS Code 打开"+ 桌面/移动分流。可验证：桌面点按钮→新标签页打开对应 cwd 的 VS Code；移动端该入口不出现，仍走 CM6。

**Phase C（3-5 天，可选）** —— 落 A2：Elixir WS 反代 + iframe 编辑区 + 认证门。
**Go 条件**：Phase B 用了一周后确实觉得"两个标签页"割裂；且愿意接受 WS 反代这块新代码的长期维护。
**No-go 信号**：反代在断线重连/大 diff/扩展 webview 下不稳定 —— 这类问题会持续消耗时间，不如停在 A1。

**Phase D（暂不做）** —— A3 深嵌 / Theia：只有在"要把 VS Code 组件拆开塞进 dala 自己的布局"成为硬需求时才重估。

### 9.6 一句话结论（修订）

**有办法，而且比集成 Theia 简单得多**：不要嵌 Theia，直接用真 VS Code 的 web 服务端（`code serve-web` 或 code-server），dala 只做"入口 + 认证 + 工作区映射 + 设备分流"，终端/会话/agent/移动端继续留在 dala。
**先跑 Phase A 的 30 分钟手工验证**，尤其是确认你要的插件在不在你选的那个市场里 —— 这一条决定了走微软官方 serve-web 还是 code-server，其余设计都跟着它走。

---

## 10. 再修订：约束"不引入 Node 服务端"之后剩下什么

用户追加硬约束：**不接受在服务端跑 Node**。这一刀砍掉 §9 的 A1/A2 —— code-server、`code serve-web`、openvscode-server、Theia 后端，本质都是一个 Node 服务进程。

### 10.1 先厘清一个绕不过去的事实

VS Code 的插件分两类（[Web Extensions 官方指南](https://code.visualstudio.com/api/extension-guides/web-extensions)）：

| | 跑在哪 | 能力 | 无 Node 服务端时 |
|---|---|---|---|
| **普通（Node）插件** | 扩展宿主进程（Node） | 全 Node API、可 spawn 进程、可用原生模块 | ❌ 不可能 |
| **Web 插件** | 浏览器里的 worker（`package.json` 声明 `browser` 入口） | 全 VS Code API + 浏览器 API + WASM；**不能** Node API / child_process / 原生模块 / 终端 / 调试 | ✅ 可以 |

**而 VS Code 内建的 git 扩展是 Node 插件**（它 spawn 的就是 `git` 命令行），所以它在浏览器里从来跑不起来 —— vscode.dev 上没有本地 git 源代码管理，就是这个原因。

**推论（必须接受的取舍）**：在"服务端无 Node"的世界里，
- "**我熟悉的 VS Code 插件**"（Copilot、Pylance、C/C++、任何带二进制的）→ **只能靠本机真 VS Code**；
- "**我熟悉的 VS Code Git 交互**"→ 在浏览器里只能是"**真 VS Code 的 SCM 面板 UI + dala 的 libgit2 做后端**"，UI 和键位是真的，git 实现是我们的。

### 10.2 路线 1：深链到你本机的真 VS Code（**推荐，成本近乎为零**）

```
dala（Phoenix，无任何新进程）
 ├─ 文件树 / git 面板 / agent 输出里的文件路径
 └─ 生成 vscode://file/<abs-path>:<line>:<col>  →  浏览器交给协议处理器
                                                  →  打开你本机那个真 VS Code
                                                     （你的全部插件、你的 git UI、你的键位，一个不少）
```

- **dala 改动面**：生成 URL 而已（文件树右键"在 VS Code 打开"、diff 行号跳转、agent 输出里的路径变可点）。**没有新进程、没有 Node、没有反代、没有新认证面。**
- URL 形态：`vscode://file/绝对路径:行:列`（[microsoft/vscode#27997](https://github.com/Microsoft/vscode/issues/27997)、[#4883](https://github.com/microsoft/vscode/issues/4883)）；Electron 客户端里还可以更直接地调 `code -g <path>:<line>`。
- **前提**：dala 与 VS Code 在**同一台机器**（`~/.local/dala` + systemd --user + 默认绑 127.0.0.1 的典型形态正好满足）。
- **远程场景的诚实说明**：如果 dala 跑在另一台机器上、你想在本机 VS Code 里编辑远端文件，那就是 Remote-SSH —— 它会在**远端跑 VS Code 自己的 node server**。那不是 dala 引入的，但如果"服务器上不能有 node"是绝对红线，这条路在远程形态下同样不可用。
- **移动端**：不受影响，继续走现有 CM6（正好是你要的分工）。

### 10.3 路线 2：monaco-vscode-api 把真 VS Code 前端搬进 dala 页面（浏览器内，服务端仍无 Node）

```
浏览器
 └── dala SPA
      └── VS Code workbench（@codingame/monaco-vscode-api，真 VS Code 代码）
           ├── FileSystemProvider ────> dala 的 Ash RPC（read/write/list/rename…）
           ├── monaco-languageclient ─> 现有 GET /lsp/ws（Elixir 桥 stdio 语言服务器，无 Node）
           ├── SCM 视图 ──────────────> dala 的 libgit2 NIF（scm-service-override 提供 SCM API）
           └── web 扩展宿主（worker/iframe）──> 只能跑 web extensions
Phoenix：零新增后端进程（只多几条已有风格的 RPC）
```

- 关键积木都存在：[service overrides 列表](https://github.com/CodinGame/monaco-vscode-api/wiki/List-of-service-overrides) 里有 `scm-service-override`（"adds the SCM API that can be used to implement source control"）、files、views、workbench、extensions；[webworker 扩展宿主](https://github.com/CodinGame/monaco-vscode-api) 在 worker/iframe 里跑扩展。
- **你能拿到的**：真 VS Code 的编辑器、键位、命令面板、设置、主题、SCM 面板长相与交互、部分 web 插件（Vim 键位、主题、纯 TS/WASM 类语言插件）。
- **你拿不到的**：Copilot / Pylance / C++ 等 Node 插件；VS Code 内建 git 扩展本体（要自己把 libgit2 接到 SCM API 上 —— 这是"自己发明一套"的一部分，只不过发明的是**适配层**，UI 是真的）。
- **代价**：构建仅支持 Linux/Mac、与 VS Code 版本强耦合（当前对齐 1.129.x，升级要跟）、`initialize` 只能调一次、包体从现在的 1.69MB min 涨到数倍；移动端仍旧 Monaco（所以移动端继续 CM6）。
- **工作量**：FS provider + SCM provider + LSP 接线 + 布局整合，粗估 2-4 周，且是长期维护项。

### 10.4 对照表

| | 路线 1 深链本机 VS Code | 路线 2 monaco-vscode-api | （已出局）code-server / serve-web |
|---|---|---|---|
| 服务端 Node | **无** | **无** | 有 ❌ |
| 你的全部插件 | **全有** | 仅 web 插件 | 全有（市场受限） |
| VS Code 内建 git | **真的** | UI 真、后端是 dala libgit2 | 真的 |
| 与 dala 同页 | 否（切到 VS Code 窗口） | **是** | iframe |
| dala 工作量 | **~1 天** | 2-4 周 + 长期维护 | 1 天 ~ 1 周 |
| 移动端 | 不受影响（CM6） | 不受影响（CM6） | 不受影响 |
| 前提 | dala 与 VS Code 同机 | 无 | 允许 Node |

### 10.5 建议

**先做路线 1**：它用一天的量给你 100% 真实的 VS Code 体验（插件、git、键位全是你自己的那套），并且完全不碰服务端形态。用一段时间后再判断"切窗口"是否真的碍事。

**只有当"必须在 dala 页面里就地编辑、不切窗口"成为强需求时，才评估路线 2**，并且要提前接受两件事：插件只剩 web 那一档、VS Code 的 SCM 面板背后是我们自己接的 libgit2。

**明确不做**：为了"在浏览器里获得完整 VS Code"而引入任何 Node 服务端（本约束下已出局）。
