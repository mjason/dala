<p align="center">
  <img src="priv/static/images/logo-512.png" width="96" alt="Dala" />
</p>

<h1 align="center">Dala</h1>

<p align="center">AI 时代的 Web 终端：长任务不怕重启、内建 Fork 级 git review、CodeMirror 全家桶。</p>

## 特性

- **持久 Shell**：每个会话跑在独立的 PTY holder 守护进程里（dtach 模型，Rust 实现），dala 重启/升级后 shell 原样恢复——tmux 的能力，浏览器的界面
- **Git review**：hunk 级与行级 stage/unstage/discard、双视角（工作区/暂存区）、分支查看与切换、提交历史按文件查看、amend（libgit2 NIF）
- **文件管理**：VS Code 式文件抽屉（上传/下载/删除/拖拽/粘贴系统文件）、Ctrl/⌘+P 快速打开
- **编辑与预览**：CodeMirror 6 语法高亮编辑器、字符级 merge diff、Markdown/CSV 预览
- **贴图给 AI**：往终端粘贴截图自动落盘，并把文件路径敲进 claude code / codex / opencode
- **自升级**：侧栏一键升级到最新 GitHub Release，升级期间 shell 不断线

## 安装（Linux x86_64）

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/install.sh | bash
```

以 systemd 用户守护进程运行，默认地址 `http://localhost:4400`。
配置在 `~/.config/dala/dala.env`（端口、可选登录 `DALA_AUTH_ENABLED` / `DALA_USERS`），数据在 `~/.local/share/dala`。

## 升级

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/update.sh | bash
```

或直接点侧栏底部的升级按钮。两种方式 shell 都不会断。

## 服务管理

```sh
systemctl --user status dala     # 状态
journalctl --user -u dala -f     # 日志
systemctl --user restart dala    # 重启（shell 存活）
```

## HTTPS / 反向代理

dala 默认只服务本机/局域网的 http（监听地址由 `DALA_LISTEN_IP` 显式控制），
`config/prod.exs` 里 Phoenix 生成器自带的 `force_ssl` 已在 v0.1.2 移除——
它只豁免 `localhost`，用局域网 IP 访问会被 301 到 `https://localhost/`。

如果以后把 dala 挂到带 TLS 的反向代理（nginx/caddy）后面，希望强制 https，
把下面这段加回 `config/prod.exs` 即可（编译期配置，改后需重新构建发布）：

```elixir
config :dala, DalaWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

同时在 `~/.config/dala/dala.env` 里设置 `PHX_SCHEME=https`、`PHX_HOST=<域名>`、
`PHX_CHECK_ORIGIN=true`。

## 架构速览

- Phoenix + Bandit 做服务端，React + xterm.js 做前端（Phoenix Channels 传输）
- 每个会话一个 `dala_holder`（Rust）：daemon 化持有 PTY，unix socket + 4 字节长度前缀帧对接 BEAM，8MB 环形缓冲兜住离线输出
- `dala_git`（Rustler + libgit2）：status/diff/stage/patch apply/branch/checkout 全走 NIF，不 shell out
- SQLite（Ash + Ecto）存账户，DETS 存会话与滚动缓存

## 从源码开发

需要 Elixir 1.19+ / OTP 28、Rust、Node 22：

```sh
mix setup
mix phx.server        # http://localhost:4000
```

发布产物由 GitHub Actions 在打 tag（`v*`）时自动构建（`.github/workflows/release.yml`）。

## License

MIT
