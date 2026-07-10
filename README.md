<p align="center">
  <img src="priv/static/images/logo-512.png" width="96" alt="Dala" />
</p>

<h1 align="center">Dala</h1>

<p align="center">A web terminal built for the AI era: long-running tasks survive restarts, Fork-grade git review built in, CodeMirror everywhere.</p>

<p align="center"><a href="README.zh-CN.md">中文文档</a></p>

---

![Dala — persistent web terminal](docs/screenshots/hero.png)

## Features

- **Persistent shells** — every session lives in its own PTY holder daemon (dtach model, written in Rust). Restarting or upgrading dala leaves your shells running: tmux durability, browser UI.
- **Git review** — hunk-level *and* line-level stage/unstage/discard, working-tree/index dual perspectives, branch switching, per-file commit browsing, amend. All through a libgit2 NIF, no shelling out.
- **Files** — VS Code-style drawer: upload/download/delete, drag & drop, paste files from the OS clipboard, `Ctrl/⌘+P` fuzzy quick-open.
- **Editing & preview** — CodeMirror 6 syntax-highlighted editor, character-level merge diffs, Markdown/CSV preview.
- **Screenshots for AI CLIs** — paste an image into the terminal; dala saves it to disk and types the file path for claude code / codex / opencode.
- **Self-upgrade** — one click in the sidebar updates to the latest GitHub release. Shells stay alive through the restart.

## Screenshots

| Git review — stage/discard per hunk | Line-level staging (`l`) |
|---|---|
| ![Git review with per-hunk actions](docs/screenshots/git-review.png) | ![Line-level staging](docs/screenshots/line-select.png) |

![Quick open](docs/screenshots/quick-open.png)

## Quick start (Linux x86_64)

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/install.sh | bash
```

This installs a prebuilt release as a systemd **user daemon** on `http://localhost:4400`.
Config lives in `~/.config/dala/dala.env`, data in `~/.local/share/dala`.

To update later — either click the sidebar update button, or:

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/update.sh | bash
```

## Desktop client

A lightweight Tauri app (Windows / macOS / Linux, ~5 MB) that manages
multiple dala servers, VS Code style:

- **Servers menu** — switch the current window between servers
  (`Ctrl/⌘+1..9`), or open a server **in a new window**; one window per
  server works like VS Code workspaces
- Sign-in state is kept per server (60-day persistent login), the last-used
  server reopens on launch
- Manage servers on the built-in page (`Ctrl/⌘+,`)

Download the installer for your OS from the
[latest release](https://github.com/mjason/dala/releases/latest)
(`.msi`/`.exe`, `.dmg`, `.deb`/`.AppImage`), or build it yourself.

> **macOS**: the app is not notarized (no paid Apple developer account), so
> Gatekeeper blocks the first launch. Run `xattr -cr /Applications/Dala.app`,
> or go to System Settings → Privacy & Security → "Open Anyway".

Build from source:

```sh
cd clients/desktop && npm install && npm run tauri build
```

## Usage guide

### Sessions

The sidebar lists your shells. `+` creates one; each runs on the server inside its
own holder process, so closing the tab, refreshing, restarting dala or upgrading
it never kills a shell. A session that *exited* (the process itself ended) shows
an overlay with a restart button. Per-session settings (rename, scrollback cache
size, kill/restart, delete) are behind the `settings` button.

### Keyboard shortcuts

| Shortcut (Linux/Windows · macOS) | Action |
|---|---|
| `Ctrl+P` · `⌘P` | Quick-open a file (fuzzy search; on macOS it works even while the terminal is focused) |
| `Ctrl+Shift+E` · `⇧⌘E` | File drawer |
| `Ctrl+Shift+G` · `⇧⌘G` | Git panel |
| `Ctrl+Shift+F` · `⇧⌘F` | Refit terminal width |
| `Ctrl+Shift+X` · `⇧⌘X` | Reset terminal |
| `Ctrl+\`` (Control on macOS too — `⌘\`` is taken by the OS) | Focus the terminal from anywhere |
| `Esc` | Close the topmost window |

File drawer: `↑↓` select · `⏎` open · `⌫` parent directory · `Del` delete ·
`Esc` deselect (uploads then target the root) · `Ctrl/⌘+V` paste a copied file.
Diff windows: `i` inline · `s` side-by-side · `l` line-select mode · `Alt+Z` wrap.
Every button shows its shortcut in a hover tooltip.

### Git panel

Open it with `Ctrl+Shift+G` in any session whose directory is inside a git repo.

- **Changes** — staged and unstaged lists (a file with both kinds of changes
  appears in both). Click a file for a syntax-highlighted diff with two
  perspectives: unstaged (index ↔ working tree) and staged (HEAD ↔ index).
- **Hunks & lines** — every change block has Stage/Discard/Unstage buttons
  (inline and side-by-side modes). Press `l` for line-select mode: tick
  individual `+`/`-` lines and stage/discard/unstage exactly those.
- **Commit** — message box at the bottom; `Amend (--amend)` melds staged
  changes into the previous commit (empty message keeps the original).
- **Branches** — click the branch name in the header to list local/remote
  branches and switch (remote branches get a local tracking branch). Dirty
  conflicts abort safely.
- **History** — commit log; multi-file commits get a file rail so you can
  review file by file.

### Images for AI CLIs

Run claude code / codex / opencode inside a dala shell and paste a screenshot
(`Ctrl/⌘+V`): dala stores it under the session directory and types its path
into the prompt — the same flow those CLIs support in a native terminal.

## Application guide

- **Long-running AI agents.** Kick off a multi-hour agent run, close the
  laptop, come back from any browser: the shell, its scrollback and the agent
  are still there. This is the core reason dala exists — terminal multiplexers
  work, but a browser tab with persistent state travels better.
- **Review what the agent wrote.** The git panel is built for the "AI writes,
  human reviews" loop: skim per-file diffs, stage exactly the lines you accept,
  discard the rest, amend fixups — without leaving the browser.
- **Multi-device access.** Expose dala on your LAN (see deployment guide),
  enable login, and drive the same shells from a phone or tablet.

## Deployment guide

### Layout

| Path | Purpose |
|---|---|
| `~/.local/dala/versions/<tag>` | unpacked releases |
| `~/.local/dala/current` | symlink to the active version |
| `~/.config/dala/dala.env` | environment file (secrets, port, toggles) |
| `~/.config/systemd/user/dala.service` | the daemon unit |
| `~/.local/share/dala` | SQLite DB, session store, scrollback cache |

The unit runs `Dala.Release.migrate()` before every start, so upgrades migrate
the database automatically. `KillMode=process` keeps PTY holders (and your
shells) alive across service restarts.

### Environment reference (`~/.config/dala/dala.env`)

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4400` | HTTP port |
| `DALA_LISTEN_IP` | `127.0.0.1` | Listen address. **Loopback only by default** — set `0.0.0.0` to serve the LAN (and enable login!) |
| `DALA_AUTH_ENABLED` | `false` | Require sign-in |
| `DALA_USERS` | — | Seeded accounts, `email:password[,email2:password2]` (min 8-char passwords; applied at boot, so it is the source of truth) |
| `PHX_HOST` / `PHX_SCHEME` / `PHX_URL_PORT` | `localhost` / `http` / `PORT` | Public URL parts (set when behind a reverse proxy) |
| `PHX_CHECK_ORIGIN` | `false` | WebSocket origin check — enable behind a reverse proxy with a fixed host |
| `DATABASE_PATH` | `~/.local/share/dala/dala.db` | SQLite location |
| `DALA_DATA_DIR` | `~/.local/share/dala` | Session store & scrollback |
| `DALA_RELEASE_ROOT` | set by install.sh | Enables the in-app updater |
| `DALA_UPDATE_REPO` / `DALA_SERVICE` | `mjason/dala` / `dala` | Updater source repo / systemd unit name |
| `SECRET_KEY_BASE` / `TOKEN_SIGNING_SECRET` | generated | Session/token secrets — keep private |

After editing: `systemctl --user restart dala` (shells survive).

### Service management

```sh
systemctl --user status dala
journalctl --user -u dala -f
systemctl --user restart dala
```

`install.sh` runs `loginctl enable-linger` so the daemon also runs while you
are logged out.

### LAN access

1. In `dala.env`: `DALA_LISTEN_IP=0.0.0.0`, `DALA_AUTH_ENABLED=true`,
   `DALA_USERS=you@example.com:yourpassword`, then restart.
2. Open `http://<machine-ip>:<port>` from another device.
3. **WSL2**: use mirrored networking (`.wslconfig` → `networkingMode=mirrored`)
   and allow the port through the Hyper-V firewall (admin PowerShell):

   ```powershell
   New-NetFirewallHyperVRule -Name dala-4400 -DisplayName "dala 4400" `
     -Direction Inbound -VMCreatorId "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}" `
     -Protocol TCP -LocalPorts 4400
   ```

A terminal server hands out your shell — never expose it without auth, and
prefer a VPN (tailscale etc.) over raw internet exposure.

### HTTPS / reverse proxy

dala serves plain http by design; TLS belongs to a reverse proxy (nginx/caddy).
The Phoenix generator's `force_ssl` block was removed in v0.1.2 (it only
exempted `localhost`, so LAN-IP access got 301-redirected to
`https://localhost/`). To force https behind a TLS proxy, put it back in
`config/prod.exs` (compile-time — requires a rebuild):

```elixir
config :dala, DalaWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

and set `PHX_SCHEME=https`, `PHX_HOST=<your-domain>`, `PHX_CHECK_ORIGIN=true`
in `dala.env`.

### Releases & building from source

Releases are built by GitHub Actions on every `v*` tag
(`.github/workflows/release.yml`): production assets (minified + digested),
Rust NIFs, the PTY holder, packaged as `dala-<tag>-linux-x86_64.tar.gz`.

Local development needs Elixir 1.19+/OTP 28, Rust and Node 22:

```sh
mix setup
mix phx.server        # http://localhost:4000
```

## Architecture

- Phoenix + Bandit server, React + xterm.js frontend (Phoenix Channels transport)
- One `dala_holder` (Rust) per session: a daemonized PTY owner with an
  **embedded headless terminal emulator** (`alacritty_terminal`) — the tmux
  model. Attaching gets a synthesized repaint (history tail + screen +
  cursor + modes) instead of a raw byte replay, so attach latency is
  independent of how much output the session ever produced and alt-screen
  apps (vim, htop) reattach pixel-perfect
- `dala_git` (Rustler + libgit2): status/diff/stage/patch-apply/branches/checkout as NIFs
- SQLite (Ash + Ecto) for accounts, DETS for sessions & scrollback cache

## License

MIT
