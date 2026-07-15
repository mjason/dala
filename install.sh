#!/usr/bin/env bash
#
# Dala installer - downloads the native release for this machine and runs it
# as a user daemon (systemd on Linux, launchd on macOS).
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/install.sh | bash
#   ./install.sh [vX.Y.Z]        # specific version (default: latest)
set -euo pipefail

REPO="${DALA_REPO:-mjason/dala}"
ROOT="${DALA_HOME:-$HOME/.local/dala}"
DATA_DIR="${DALA_DATA_DIR:-$HOME/.local/share/dala}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dala"
ENV_FILE="$CONFIG_DIR/dala.env"
PORT="${DALA_PORT:-4400}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)
    PLATFORM="linux-x86_64"
    SERVICE_MANAGER="systemd"
    SERVICE_NAME="dala"
    SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    command -v systemctl >/dev/null || die "systemd (systemctl --user) is required"
    ;;
  Darwin/arm64)
    PLATFORM="macos-arm64"
    SERVICE_MANAGER="launchd"
    SERVICE_NAME="com.manjialin.dala"
    SERVICE_DIR="$HOME/Library/LaunchAgents"
    command -v launchctl >/dev/null || die "launchctl is required"
    ;;
  *)
    die "no prebuilt release for $(uname -s)/$(uname -m)"
    ;;
esac

# --- resolve version ---------------------------------------------------------
TAG="${1:-}"
if [ -z "$TAG" ]; then
  say "resolving latest release of $REPO"
  # Skip client-v* tags: the repo also publishes desktop-client releases.
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=15" |
    grep '"tag_name"' | cut -d'"' -f4 | grep -m1 '^v[0-9]') || true
  [ -n "$TAG" ] || die "could not resolve the latest release (does $REPO have releases?)"
fi
ASSET="dala-$TAG-$PLATFORM.tar.gz"
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
    if [ "$PLATFORM" = "macos-arm64" ]; then
      (cd "$TMP" && shasum -a 256 -c "$ASSET.sha256" >/dev/null) || die "checksum mismatch"
    else
      (cd "$TMP" && sha256sum -c "$ASSET.sha256" >/dev/null) || die "checksum mismatch"
    fi
    say "checksum ok"
  fi
  mkdir -p "$DEST"
  tar -xzf "$TMP/$ASSET" -C "$DEST"
fi

# --- environment (first install only) ---------------------------------------
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$SERVICE_DIR"
if [ ! -f "$ENV_FILE" ]; then
  say "writing $ENV_FILE"
  gen_secret() { head -c 48 /dev/urandom | base64 | tr -d '\n='; }
  cat > "$ENV_FILE" <<EOF
# Dala runtime configuration (loaded by the user service).
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
DALA_SERVICE=$SERVICE_NAME
SECRET_KEY_BASE=$(gen_secret)
TOKEN_SIGNING_SECRET=$(gen_secret)
# Optional login (default: open, local use). Enable with:
#   DALA_AUTH_ENABLED=true
#   DALA_USERS=you@example.com:yourpassword
# DALA_USERS is BOOTSTRAP-ONLY: the account is created on first boot and
# never reset afterwards - REMOVE the line after the service comes up so
# the plaintext password does not linger in this file.
# Forgot the password? Put the line back plus DALA_USERS_RESET=true for
# one boot, then remove both.
EOF
  chmod 600 "$ENV_FILE"
else
  say "keeping existing $ENV_FILE"
fi

# --- service -----------------------------------------------------------------
ln -sfn "$DEST" "$ROOT/current"

if [ "$SERVICE_MANAGER" = "systemd" ]; then
  say "installing systemd user service"
  cat > "$SERVICE_DIR/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Dala terminal server
After=network.target

[Service]
Type=exec
EnvironmentFile=$ENV_FILE
ExecStartPre=$ROOT/current/bin/dala eval "Dala.Release.migrate()"
ExecStart=$ROOT/current/bin/dala start
ExecStop=$ROOT/current/bin/dala stop
# Only the BEAM dies on restart; detached PTY holders keep shells alive.
KillMode=process
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  say "starting $SERVICE_NAME ($TAG)"
  systemctl --user restart "$SERVICE_NAME"
  loginctl enable-linger "$USER" 2>/dev/null || true
else
  say "installing launchd user service"
  RUNNER="$ROOT/run-dala"
  PLIST="$SERVICE_DIR/$SERVICE_NAME.plist"
  cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -x /usr/libexec/path_helper ]; then
  eval "\$(/usr/libexec/path_helper -s)"
fi
set -a
. "$ENV_FILE"
set +a
"$ROOT/current/bin/dala" eval "Dala.Release.migrate()"
exec "$ROOT/current/bin/dala" start
EOF
  chmod 700 "$RUNNER"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVICE_NAME</string>
  <key>ProgramArguments</key>
  <array><string>$RUNNER</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>StandardOutPath</key><string>$DATA_DIR/dala.stdout.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/dala.stderr.log</string>
</dict>
</plist>
EOF

  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/$SERVICE_NAME" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  launchctl enable "$DOMAIN/$SERVICE_NAME" 2>/dev/null || true
  say "starting $SERVICE_NAME ($TAG)"
  launchctl kickstart -k "$DOMAIN/$SERVICE_NAME"
fi

# --- prune old versions (keep 3) --------------------------------------------
ls -1dt "$ROOT"/versions/* 2>/dev/null | tail -n +4 | while read -r old; do
  [ "$old" = "$DEST" ] && continue
  say "pruning $(basename "$old")"
  rm -rf "$old"
done

# --- health check ------------------------------------------------------------
PORT_NOW=$(grep -m1 '^PORT=' "$ENV_FILE" | cut -d= -f2)
ATTEMPT=0
while [ "$ATTEMPT" -lt 30 ]; do
  if curl -fso /dev/null "http://localhost:$PORT_NOW"; then
    say "dala $TAG is running: http://localhost:$PORT_NOW"
    exit 0
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 1
done

if [ "$SERVICE_MANAGER" = "systemd" ]; then
  die "service did not become healthy - check: journalctl --user -u $SERVICE_NAME -n 50"
else
  die "service did not become healthy - check: tail -n 50 $DATA_DIR/dala.stderr.log"
fi
