<p align="center">
  <img src="priv/static/images/logo-512.png" width="96" alt="Dala" />
</p>

<h1 align="center">Dala</h1>

<p align="center">AI 时代的 Web 终端：长任务不怕重启、内建 Fork 级 git review、CodeMirror 全家桶。</p>

<p align="center"><a href="README.md">English</a></p>

---

![Dala — 持久化 Web 终端](docs/screenshots/hero.png)

## 特性

- **持久 Shell** — 每个会话跑在独立的 PTY holder 守护进程里（dtach 模型，Rust 实现）。重启、升级 dala，shell 原样存活：tmux 的可靠性，浏览器的界面。
- **Git review** — hunk 级 **和** 行级的 stage/unstage/discard、工作区/暂存区双视角、分支切换、提交历史按文件查看、amend。全部走 libgit2 NIF，不 shell out。
- **文件管理** — VS Code 式抽屉：上传/下载/删除、拖拽、粘贴系统剪贴板里的文件、`Ctrl/⌘+P` 模糊快速打开。
- **编辑与预览** — CodeMirror 6 语法高亮编辑器、字符级 merge diff、Markdown/CSV 预览。
- **贴图给 AI CLI** — 往终端粘贴截图，dala 自动落盘并把文件路径敲进 claude code / codex / opencode 的提示符。
- **自升级** — 侧栏一键升级到最新 GitHub Release，升级期间 shell 不断线。

## 截图

| Git review——按 hunk 暂存/丢弃 | 行级暂存（`l`） |
|---|---|
| ![hunk 级操作](docs/screenshots/git-review.png) | ![行级暂存](docs/screenshots/line-select.png) |

![快速打开](docs/screenshots/quick-open.png)

## 快速开始（Linux x86_64）

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/install.sh | bash
```

以 systemd **用户守护进程**安装预编译包，地址 `http://localhost:4400`。
配置在 `~/.config/dala/dala.env`，数据在 `~/.local/share/dala`。

升级：点侧栏的升级按钮，或者：

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/update.sh | bash
```

## 桌面客户端

Electron 应用（Windows / macOS / Linux），VS Code 式管理多台 dala 服务器。
统一 Chromium 内核：渲染、输入法、剪贴板在所有平台上与 Chrome 表现完全一致：

- **服务器菜单** — 当前窗口一键切换服务器（`Ctrl/⌘+1..9`），
  或**在新窗口打开**另一台；一窗口一服务器，像 VS Code 的多工作区
- 每台服务器的登录状态独立保存（60 天免登录），启动直达上次连接的服务器
- 内置管理页添加/删除服务器（`Ctrl/⌘+,`）
- 终端里的外部链接在内置浏览器窗口打开

客户端使用独立的 tag（`client-vX.Y.Z`）发版，与服务端（`vX.Y.Z`）互不
影响，因此它不会带「Latest」徽标——直接从
[客户端 Releases](https://github.com/mjason/dala/releases?q=client&expanded=true)
下载对应系统的安装包（`.exe`、`.dmg`、`.deb`/`.AppImage`）。

> **macOS**：universal `.dmg`（Apple Silicon + Intel）已签名并通过 Apple
> 公证（Developer ID），双击直接打开，无任何 Gatekeeper 弹窗。

> 从 Tauri 版客户端（≤ v0.5.x）升级？首次启动会自动导入原有服务器列表。

> **自动升级**：client-v0.1.2 起客户端自动检查新版本（启动后及每 4 小时），
> 后台下载完成后提示一键重启安装；菜单「文件 → 检查更新」可手动触发。

源码构建：

```sh
cd clients/desktop && npm install && npm run build
```

## 使用指南

### 会话

侧栏列出你的所有 shell，`+` 新建。每个 shell 都在服务端独立的 holder 进程里运行：
关标签页、刷新、重启 dala、升级版本都不会杀死 shell。只有 shell 进程自己退出时
才会出现重启浮层。会话设置（改名、滚动缓存大小、结束/重启、删除）在 `settings` 按钮里；如果 zellij/tmux 被别处遗忘的窗口压小（右边和底部空一圈），设置里的「断开其他查看端」可一键把其他客户端踢掉。

### 快捷键

| 快捷键（Linux/Windows · macOS） | 功能 |
|---|---|
| `Ctrl+P` · `⌘P` | 快速打开文件（模糊搜索；macOS 下终端聚焦时也可用） |
| `Ctrl+Shift+E` · `⇧⌘E` | 文件抽屉 |
| `Ctrl+Shift+G` · `⇧⌘G` | Git 面板 |
| `Ctrl+Shift+F` · `⇧⌘F` | 重排终端宽度 |
| `Ctrl+Shift+X` · `⇧⌘X` | 重置终端 |
| `Ctrl+Shift+K` · `⇧⌘K`（或点终端底部输入条）| **Composer**（Warp 式富输入）：CodeMirror Markdown 编辑器（代码块高亮、Tab 缩进、Enter 换行）、**Shift+Enter 整句送入** Claude Code/opencode、`@` 引用文件、`/` 命令补全（含自定义命令/skills）、`+` 附件 |
| `Ctrl+\``（Mac 也是 Control 键——`⌘\`` 被系统的窗口切换占用） | 从任何地方聚焦回终端 |
| `Ctrl+Shift+\``（或顶栏 `⚡>_` 按钮） | **快速 shell**：一次性弹层终端（盖在当前会话上，左缘可拖宽，可一键全屏），秒开且直接落在当前会话目录，面板内 `+` 可开多个标签。**Esc 即关**——所有快速 shell 当场销毁，用完就没有（vim 等全屏程序里 Esc 归程序）；单个标签也可 `exit`/`Ctrl+D` 关闭 |
| `Esc` | 关闭最顶层窗口 |

侧栏、快速 shell、文件抽屉、Git 面板的边缘均可拖拽调宽（记忆到浏览器）；双击分割线恢复该面板默认宽，设置里有「恢复默认布局」一键全部复位。

文件抽屉：`↑↓` 选择 · `⏎` 打开 · `⌫` 上级目录 · `Del` 删除 ·
`Esc` 取消选中（此时上传落到根目录）· `Ctrl/⌘+V` 粘贴复制的文件。
Diff 窗口：`i` 单栏 · `s` 并排 · `l` 行选模式 · `Alt+Z` 折行。
每个按钮悬停都有快捷键提示。

### Git 面板

在仓库目录的会话里按 `Ctrl+Shift+G` 打开。

- **变更** — 已暂存/未暂存两个列表（同时有两种改动的文件在两边都出现）。
  点文件看语法高亮 diff，双视角：未暂存（index ↔ 工作区）、已暂存（HEAD ↔ index）。
- **Hunk 与行** — 每个改动块都有 Stage/Discard/Unstage 按钮（单栏、并排都有）。
  按 `l` 进入行选模式：逐行勾选 `+`/`-`，只操作选中的行。
- **提交** — 底部消息框；`修改上次提交 (--amend)` 把已暂存改动并入上一条提交
  （消息留空则保留原文）。
- **分支** — 点头部分支名列出本地/远程分支并切换（远程分支自动建本地跟踪分支），
  有冲突的脏工作区会安全报错不强切。
- **历史** — 提交日志；多文件提交带文件栏，可逐文件审阅。

### Agent 感知（Claude Code / opencode / Codex…）

dala 讲 Warp 的开源 cli-agent 协议（OSC 777）。给 agent 装上对应
插件后即可启用（一次性配置）：

**Claude Code**（在 Claude Code 里执行，装完重启它或 `/reload-plugins`）：

```
/plugin marketplace add warpdotdev/claude-code-warp
/plugin install warp@claude-code-warp
```

**opencode**（`opencode.json` 加一行）：

```json
{ "plugin": ["@warp-dot-dev/opencode-warp"] }
```

**Codex**：无需插件，原生通知即可。**Gemini CLI**：装
`warpdotdev/gemini-cli-warp`（见其仓库 README）。

启用后：

- **通知**：任务完成 / 等待授权 / 向你提问时，若你在别的会话或切走了
  窗口，弹系统通知（点击直达该会话）
- **侧栏状态点**：✳ 干活中（薄荷脉冲）/ ⏳ 等你（琥珀脉冲）/ ✓ 完成
  （蓝色，点开会话即清除）
- **Composer 自动开合**：agent 干活/完成时自动展开输入条备稿（不抢
  焦点），等待授权时自动收起（授权要在终端里按键）

Codex 无需插件（原生 OSC 9 通知即可触发完成提醒）。注意 zellij/tmux
不透传内层 OSC，插件事件在多路复用器里收不到。已运行的旧会话需重启
其 shell 才启用（holder 随发版更新，但存量进程仍是旧的）。

### 目录跟随与 zellij/tmux

文件抽屉跟随终端的当前目录，**zellij/tmux 内部无需任何配置**：dala
检测到会话里跑着多路复用器后，直接向它查询**聚焦 pane** 的目录
（zellij 走 `dump-layout`，tmux 走 `pane_current_path`），切 pane、
切 tab 都会跟。注意 zellij/tmux 并不向外透传 pane 里的 OSC 7，所以
shell 钩子帮不了这个场景。

不用多路复用器时靠顶层 shell 轮询（2s）即可；想要 `cd` 即时生效，
可选配 **OSC 7** 上报，在 `~/.zshrc` 加：

```zsh
_osc7() { printf '\e]7;file://%s%s\a' "$HOST" "$PWD" }
autoload -U add-zsh-hook && add-zsh-hook chpwd _osc7 && _osc7
```

bash 用户（`~/.bashrc`）：

```bash
PROMPT_COMMAND='printf "\e]7;file://%s%s\a" "$HOSTNAME" "$PWD"'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

（很多发行版的 vte.sh、WezTerm/Kitty 的 shell integration 已自带 OSC 7。）

### 给 AI CLI 贴图

在 dala 的 shell 里跑 claude code / codex / opencode，直接粘贴截图
（`Ctrl/⌘+V`）：dala 把图片存到会话目录并把路径敲进提示符——
和原生终端里这些 CLI 支持的流程一致。

## 项目配置：dala.jsonc

一切默认零配置——编辑器的 LSP 按项目自动解析服务器（Python venv 里的
basedpyright、rust-analyzer、elixir-ls、typescript-language-server、gopls……
依次探测 venv、PATH、`~/.local/bin`、`~/.cargo/bin`、Mason）。默认不够用时，
在项目根放一个 `dala.jsonc` 接管。支持注释和尾逗号。

```jsonc
{
  // 按语言覆盖挂载的语言服务器。同一个文件可以挂多个
  // （比如框架自带的 DSL 服务器和 pyright 并行）。
  "lsp": {
    "python": [
      { "command": [".venv/bin/basedpyright-langserver", "--stdio"] },
      { "command": [".venv/bin/dm", "lsp"] },          // 框架 DSL 服务器
    ],
  },

  // monorepo：把子项目映射到各自的根。路径前缀最长匹配生效；
  // LSP 的 rootUri 和工作目录都落在子项目。
  "projects": {
    "assets": {                                         // 前端在 <root>/assets
      "lsp": { "typescript": [ { "command": ["node_modules/.bin/tsls", "--stdio"] } ] },
    },
    "clients/desktop": {},                              // {} = 在该子根自动探测
  },
}
```

规则：

- **命令词支持变量展开**：`~`、`$VAR` / `${VAR}`、`${root}`（项目根）。
  相对路径按项目根解析。
- **就近配置优先**：子目录里的 `dala.jsonc` 对其下的文件覆盖顶层配置——
  和 `"projects"` 二选一均可。
- `"projects"` 条目即使没写 `"lsp"` 也会改变根：自动探测会在*子项目*
  进行（它自己的 venv、它自己的 node_modules）。
- 旧格式 `.dala/lsp.json`（整个文件就是 lsp 映射）继续兼容；
  两者并存时 `dala.jsonc` 优先。
- 编辑器的 **LSP 调试窗**逐文件显示命中的配置和每个探测路径（✓/✗）——
  同样的数据在 `GET /lsp/debug`，AI agent 可直接读取。

## 应用指南

- **长时间跑 AI agent。** 发起一个几小时的 agent 任务，合上笔记本，之后在任何
  浏览器里回来：shell、滚动历史、agent 都还在。这是 dala 存在的核心理由——
  终端复用器也能做到，但一个带持久状态的浏览器标签页更方便携带。
- **审 AI 写的代码。** git 面板就是为「AI 写、人审」设计的：逐文件看 diff，
  只暂存你认可的行，丢弃其余，amend 补丁——全程不离开浏览器。
- **多设备访问。** 把 dala 暴露到局域网（见部署指南），开启登录，
  用手机/平板操作同一批 shell。

## 部署指南

### 目录布局

| 路径 | 用途 |
|---|---|
| `~/.local/dala/versions/<tag>` | 解包后的各版本 |
| `~/.local/dala/current` | 指向当前版本的符号链接 |
| `~/.config/dala/dala.env` | 环境配置（密钥、端口、开关） |
| `~/.config/systemd/user/dala.service` | 守护进程 unit |
| `~/.local/share/dala` | SQLite 数据库、会话存储、滚动缓存 |

unit 每次启动前先跑 `Dala.Release.migrate()`，升级自动迁移数据库；
`KillMode=process` 保证服务重启时 PTY holder（以及你的 shell）不被杀。

### 环境变量参考（`~/.config/dala/dala.env`）

| 变量 | 默认 | 含义 |
|---|---|---|
| `PORT` | `4400` | HTTP 端口 |
| `DALA_LISTEN_IP` | `127.0.0.1` | 监听地址。**默认仅本机**——设 `0.0.0.0` 暴露局域网（务必同时开登录！） |
| `DALA_AUTH_ENABLED` | `false` | 是否要求登录 |
| `DALA_USERS` | — | 预置账号，`email:password[,email2:password2]`（密码至少 8 位；每次启动生效，以此为准） |
| `PHX_HOST` / `PHX_SCHEME` / `PHX_URL_PORT` | `localhost` / `http` / 同 `PORT` | 对外 URL 组成（挂反代时设置） |
| `PHX_CHECK_ORIGIN` | `false` | WebSocket 来源校验——固定域名的反代后面建议开 |
| `DATABASE_PATH` | `~/.local/share/dala/dala.db` | SQLite 位置 |
| `DALA_DATA_DIR` | `~/.local/share/dala` | 会话存储与滚动缓存 |
| `DALA_RELEASE_ROOT` | install.sh 设置 | 存在时启用应用内升级 |
| `DALA_UPDATE_REPO` / `DALA_SERVICE` | `mjason/dala` / `dala` | 升级源仓库 / systemd unit 名 |
| `SECRET_KEY_BASE` / `TOKEN_SIGNING_SECRET` | 自动生成 | 会话/令牌密钥——注意保密 |

改完执行 `systemctl --user restart dala`（shell 存活）。

### 服务管理

```sh
systemctl --user status dala
journalctl --user -u dala -f
systemctl --user restart dala
```

`install.sh` 已执行 `loginctl enable-linger`，注销后守护进程照常运行。

### 局域网访问

1. `dala.env` 里：`DALA_LISTEN_IP=0.0.0.0`、`DALA_AUTH_ENABLED=true`、
   `DALA_USERS=you@example.com:yourpassword`，然后重启服务。
2. 其他设备访问 `http://<机器IP>:<端口>`。
3. **WSL2**：使用镜像网络（`.wslconfig` → `networkingMode=mirrored`），
   并放行 Hyper-V 防火墙端口（管理员 PowerShell）：

   ```powershell
   New-NetFirewallHyperVRule -Name dala-4400 -DisplayName "dala 4400" `
     -Direction Inbound -VMCreatorId "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}" `
     -Protocol TCP -LocalPorts 4400
   ```

终端服务器交出去的是你的 shell——没有登录保护绝不要暴露；
公网访问优先走 VPN（如 tailscale），不要裸暴露。

### HTTPS / 反向代理

dala 设计上只提供 http，TLS 交给前置反代（nginx/caddy）。
Phoenix 生成器自带的 `force_ssl` 已在 v0.1.2 移除——它只豁免 `localhost`，
用局域网 IP 访问会被 301 到 `https://localhost/`。如果以后挂了 TLS 反代想
强制 https，把这段加回 `config/prod.exs`（编译期配置，需重新构建发布）：

```elixir
config :dala, DalaWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

并在 `dala.env` 设置 `PHX_SCHEME=https`、`PHX_HOST=<域名>`、`PHX_CHECK_ORIGIN=true`。

### 发布与源码构建

发布产物由 GitHub Actions 在打 `v*` tag 时自动构建
（`.github/workflows/release.yml`）：生产前端（minify + digest）、Rust NIF、
PTY holder，打包为 `dala-<tag>-linux-x86_64.tar.gz`。

本地开发需要 Elixir 1.19+/OTP 28、Rust、Node 22：

```sh
mix setup
mix phx.server        # http://localhost:4000
```

## 架构速览

- Phoenix + Bandit 服务端，React + xterm.js 前端（Phoenix Channels 传输）
- 每会话一个 `dala_holder`（Rust）：daemon 化持有 PTY，**内嵌无头终端模拟器**
  （`alacritty_terminal`）——tmux 模型。attach 拿到的是合成重绘
  （历史尾部 + 当前屏 + 光标 + 模式），不再重放原始字节流，attach 耗时与
  历史输出总量无关，vim/htop 这类全屏应用跨重启精确恢复
- `dala_git`（Rustler + libgit2）：status/diff/stage/patch apply/分支/checkout 全走 NIF
- SQLite（Ash + Ecto）存账户，DETS 存会话与滚动缓存

## License

MIT
