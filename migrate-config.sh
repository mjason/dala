#!/usr/bin/env bash
#
# Dala config migration - moves a legacy dala.env install to config.jsonc so
# the service process carries NO dala environment variables (nothing can
# leak into the shells it spawns).
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/migrate-config.sh | bash
#
# Idempotent and reversible: dala.env is kept as dala.env.migrated-<date>;
# restoring the old name (and re-adding EnvironmentFile on Linux) rolls back.
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dala"
ENV_FILE="$CONFIG_DIR/dala.env"
CONFIG_FILE="$CONFIG_DIR/config.jsonc"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no $ENV_FILE found - nothing to migrate (already on config.jsonc?)"
[ -f "$CONFIG_FILE" ] && die "$CONFIG_FILE already exists - refusing to overwrite (delete it to redo)"

# --- read the legacy env file ------------------------------------------------
envval() { grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- || true; }

PORT=$(envval PORT); PORT="${PORT:-4400}"
LISTEN_IP=$(envval DALA_LISTEN_IP); LISTEN_IP="${LISTEN_IP:-127.0.0.1}"
HOST=$(envval PHX_HOST); HOST="${HOST:-localhost}"
CHECK_ORIGIN=$(envval PHX_CHECK_ORIGIN); CHECK_ORIGIN="${CHECK_ORIGIN:-false}"
DATA_DIR=$(envval DALA_DATA_DIR); DATA_DIR="${DATA_DIR:-$HOME/.local/share/dala}"
DB_PATH=$(envval DATABASE_PATH)
RELEASE_ROOT=$(envval DALA_RELEASE_ROOT); RELEASE_ROOT="${RELEASE_ROOT:-$HOME/.local/dala}"
SERVICE=$(envval DALA_SERVICE)
AUTH_ENABLED=$(envval DALA_AUTH_ENABLED); AUTH_ENABLED="${AUTH_ENABLED:-false}"
SECRET_KEY_BASE=$(envval SECRET_KEY_BASE)
TOKEN_SIGNING_SECRET=$(envval TOKEN_SIGNING_SECRET)
SCHEME=$(envval PHX_SCHEME)
URL_PORT=$(envval PHX_URL_PORT)

case "$(uname -s)" in
  Darwin) DEFAULT_SERVICE="com.manjialin.dala" ;;
  *) DEFAULT_SERVICE="dala" ;;
esac
SERVICE="${SERVICE:-$DEFAULT_SERVICE}"

if envval DALA_USERS | grep -q .; then
  say "NOTE: dala.env still contains DALA_USERS - accounts are already"
  say "      persisted in the database, the line is NOT migrated (it held a"
  say "      plaintext password). Re-add auth.users in config.jsonc only for"
  say "      a password reset."
fi

# --- secrets move into the data dir (0600), never into the config file -------
mkdir -p "$DATA_DIR"
SECRETS_FILE="$DATA_DIR/secrets.json"
if [ ! -f "$SECRETS_FILE" ] && [ -n "$SECRET_KEY_BASE" ]; then
  say "moving secrets to $SECRETS_FILE"
  cat > "$SECRETS_FILE" <<SECEOF
{
  "secretKeyBase": "$SECRET_KEY_BASE",
  "tokenSigningSecret": "$TOKEN_SIGNING_SECRET"
}
SECEOF
  chmod 600 "$SECRETS_FILE"
fi

# --- write config.jsonc ------------------------------------------------------
say "writing $CONFIG_FILE"
{
  echo "{"
  echo "  // Dala server configuration (migrated from dala.env). Restart the"
  echo "  // service after editing."
  echo "  \"server\": true,"
  echo "  \"port\": $PORT,"
  echo "  \"listenIp\": \"$LISTEN_IP\","
  echo "  \"host\": \"$HOST\","
  echo "  \"checkOrigin\": $( [ "$CHECK_ORIGIN" = "true" ] || [ "$CHECK_ORIGIN" = "1" ] && echo true || echo false ),"
  echo "  \"dataDir\": \"$DATA_DIR\","
  [ -n "$DB_PATH" ] && echo "  \"databasePath\": \"$DB_PATH\","
  [ -n "$SCHEME" ] && echo "  \"scheme\": \"$SCHEME\","
  [ -n "$URL_PORT" ] && echo "  \"urlPort\": $URL_PORT,"
  echo "  \"releaseRoot\": \"$RELEASE_ROOT\","
  echo "  \"serviceName\": \"$SERVICE\","
  echo "  \"auth\": { \"enabled\": $( [ "$AUTH_ENABLED" = "true" ] || [ "$AUTH_ENABLED" = "1" ] && echo true || echo false ) },"
  echo "}"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# --- retire the env file -----------------------------------------------------
BACKUP="$ENV_FILE.migrated-$(date +%Y%m%d%H%M%S)"
mv "$ENV_FILE" "$BACKUP"
say "kept a backup at $BACKUP"

# --- drop EnvironmentFile from the service and restart -----------------------
if [ "$(uname -s)" = "Linux" ]; then
  UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE.service"
  if [ -f "$UNIT" ] && grep -q "^EnvironmentFile=" "$UNIT"; then
    say "removing EnvironmentFile from $UNIT"
    sed -i "/^EnvironmentFile=/d" "$UNIT"
    systemctl --user daemon-reload
  fi
  say "restarting $SERVICE"
  systemctl --user restart "$SERVICE"
else
  # macOS: the runner only sources dala.env when it exists - renaming it was
  # enough. Restart to pick up the config file.
  say "restarting $SERVICE"
  launchctl kickstart -k "gui/$(id -u)/$SERVICE"
fi

# --- health check ------------------------------------------------------------
ATTEMPT=0
while [ "$ATTEMPT" -lt 30 ]; do
  if curl -fso /dev/null "http://localhost:$PORT"; then
    say "migrated - dala is running on config.jsonc: http://localhost:$PORT"
    say "the service process now carries no dala environment variables"
    exit 0
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 1
done

die "service did not come back - roll back with: mv '$BACKUP' '$ENV_FILE' (and re-add EnvironmentFile on Linux), then restart"
