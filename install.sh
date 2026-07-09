#!/usr/bin/env bash
#
# Dala installer — downloads the prebuilt release from GitHub and runs it as
# a systemd user daemon. Shells survive restarts/upgrades (PTY holders).
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/install.sh | bash
#   ./install.sh [vX.Y.Z]        # specific version (default: latest)
#
# Layout:
#   ~/.local/dala/versions/<tag>   unpacked releases
#   ~/.local/dala/current          symlink to the active version
#   ~/.local/share/dala            data (DB, uploads, scrollback)
#   ~/.config/dala/dala.env        environment (secrets, port)
set -euo pipefail

REPO="${DALA_REPO:-mjason/dala}"
ROOT="${DALA_HOME:-$HOME/.local/dala}"
DATA_DIR="${DALA_DATA_DIR:-$HOME/.local/share/dala}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dala"
ENV_FILE="$CONFIG_DIR/dala.env"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="dala"
PORT="${DALA_PORT:-4400}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"
command -v systemctl >/dev/null || die "systemd (systemctl --user) is required"
[ "$(uname -s)/$(uname -m)" = "Linux/x86_64" ] || die "prebuilt releases only cover linux-x86_64 (got $(uname -s)/$(uname -m))"

# --- resolve version ---------------------------------------------------------
TAG="${1:-}"
if [ -z "$TAG" ]; then
  say "resolving latest release of $REPO"
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
    grep -m1 '"tag_name"' | cut -d'"' -f4) || true
  [ -n "$TAG" ] || die "could not resolve the latest release (does $REPO have releases?)"
fi
ASSET="dala-$TAG-linux-x86_64.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
DEST="$ROOT/versions/$TAG"

# --- download + unpack -------------------------------------------------------
if [ -x "$DEST/bin/dala" ]; then
  say "$TAG already downloaded"
else
  say "downloading $ASSET"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fSL --progress-bar -o "$TMP/$ASSET" "$URL"
  if curl -fsSL -o "$TMP/$ASSET.sha256" "$URL.sha256" 2>/dev/null; then
    (cd "$TMP" && sha256sum -c "$ASSET.sha256" >/dev/null) || die "checksum mismatch"
    say "checksum ok"
  fi
  mkdir -p "$DEST"
  tar -xzf "$TMP/$ASSET" -C "$DEST"
fi

# --- environment (first install only) ---------------------------------------
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$UNIT_DIR"
if [ ! -f "$ENV_FILE" ]; then
  say "writing $ENV_FILE"
  gen_secret() { head -c 48 /dev/urandom | base64 | tr -d '\n='; }
  cat > "$ENV_FILE" <<EOF
# Dala runtime configuration (loaded by the systemd unit).
PHX_SERVER=true
PORT=$PORT
PHX_HOST=localhost
# Loopback only by default. LAN access: DALA_LISTEN_IP=0.0.0.0 (then enable
# login below!).
DALA_LISTEN_IP=127.0.0.1
# Reached from other machines? Keep check_origin off, or set PHX_HOST and
# PHX_CHECK_ORIGIN=true behind a reverse proxy.
PHX_CHECK_ORIGIN=false
DATABASE_PATH=$DATA_DIR/dala.db
DALA_DATA_DIR=$DATA_DIR
DALA_RELEASE_ROOT=$ROOT
SECRET_KEY_BASE=$(gen_secret)
TOKEN_SIGNING_SECRET=$(gen_secret)
# Optional login (default: open, local use). Enable with:
#   DALA_AUTH_ENABLED=true
#   DALA_USERS=you@example.com:yourpassword
EOF
  chmod 600 "$ENV_FILE"
else
  say "keeping existing $ENV_FILE"
fi

# --- systemd unit -------------------------------------------------------------
say "installing systemd user service"
cat > "$UNIT_DIR/$SERVICE.service" <<EOF
[Unit]
Description=Dala terminal server
After=network.target

[Service]
Type=exec
EnvironmentFile=$ENV_FILE
ExecStartPre=$ROOT/current/bin/dala eval "Dala.Release.migrate()"
ExecStart=$ROOT/current/bin/dala start
ExecStop=$ROOT/current/bin/dala stop
# Only the BEAM dies on stop/restart — the per-session PTY holder daemons
# stay in the cgroup and keep the shells alive across upgrades.
KillMode=process
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

# --- activate ------------------------------------------------------------------
ln -sfn "$DEST" "$ROOT/current"
systemctl --user daemon-reload
systemctl --user enable "$SERVICE" >/dev/null 2>&1 || true
say "starting $SERVICE ($TAG)"
systemctl --user restart "$SERVICE"
loginctl enable-linger "$USER" 2>/dev/null || true

# --- prune old versions (keep 3) ----------------------------------------------
ls -1dt "$ROOT"/versions/* 2>/dev/null | tail -n +4 | while read -r old; do
  [ "$old" = "$DEST" ] && continue
  say "pruning $(basename "$old")"
  rm -rf "$old"
done

# --- health check ---------------------------------------------------------------
PORT_NOW=$(grep -m1 '^PORT=' "$ENV_FILE" | cut -d= -f2)
for _ in $(seq 1 30); do
  if curl -fso /dev/null "http://localhost:$PORT_NOW"; then
    say "dala $TAG is running: http://localhost:$PORT_NOW"
    exit 0
  fi
  sleep 1
done
die "service did not become healthy — check: journalctl --user -u $SERVICE -n 50"
