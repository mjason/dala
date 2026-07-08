# Dala

A web terminal that survives your refresh — think "web tmux". Shells run on
the server in real PTYs; the browser is just a view that can disconnect,
refresh and reattach without losing anything.

## How it works

- **PTY**: a Rustler NIF (`native/dala_pty`) wraps the Rust
  [`portable-pty`](https://crates.io/crates/portable-pty) crate. A reader
  thread streams PTY output straight into the owning `Dala.Terminal.Server`
  GenServer as messages.
- **OTP**: one `Dala.Terminal.Server` per session under a
  `DynamicSupervisor`, addressed via `Registry`. Output is broadcast on
  `terminal:{id}`; session lifecycle events on `sessions`.
- **Scrollback**: every output chunk is cached in DETS
  (`Dala.Terminal.Scrollback`) with a per-session byte limit that is
  adjustable from the UI. Refresh, reconnect — even a server restart — replays
  the cached history.
- **Push**: `AshTypescript.TypedChannel` generates typed channel
  subscriptions (`output`, `replay`, `exit`, `cwd`, `session_*`) consumed by
  the React frontend; CRUD and the file manager go through AshTypescript RPC.
- **UI**: React + xterm.js. Sessions sidebar, drawer file manager that follows
  the shell's cwd (`/proc/<pid>/cwd`), file previews, per-session settings.

## Running

```bash
mix setup
mix phx.server          # http://localhost:4000
```

Requires a Rust toolchain (for the PTY NIF) and Linux (cwd tracking reads
`/proc`; WSL2 works).

## Optional authentication

Authentication is off by default. To enable it, boot with pre-seeded
accounts — there is no self-registration or password reset:

```bash
DALA_AUTH_ENABLED=true \
DALA_USERS="admin@example.com:changeme123,dev@example.com:alsochangeme" \
mix phx.server
```

`DALA_USERS` is re-applied on every boot, so it is the source of truth for
credentials. With auth enabled the SPA, the RPC endpoint and the websocket all
require a signed-in user.

Other knobs:

| Env | Default | Purpose |
|-----|---------|---------|
| `DALA_AUTH_ENABLED` | `false` | Require sign-in |
| `DALA_USERS` | – | Seeded `email:password` accounts |
| `DALA_DATA_DIR` | `priv/data` | Where the DETS scrollback cache lives |
| `PORT` | `4000` | HTTP port |

## Development

```bash
mix precommit                # compile --warnings-as-errors, format, tests
mix ash_typescript.codegen   # regenerate assets/js/ash_rpc.ts & friends
cd assets && npx tsc -p tsconfig.json   # typecheck the frontend
```
