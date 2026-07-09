#!/usr/bin/env bash
#
# Dala updater — fetches the latest GitHub release, switches the `current`
# symlink and restarts the daemon. Running shells survive the restart (each
# lives in its own PTY holder process).
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/update.sh | bash
#   ./update.sh [vX.Y.Z]
set -euo pipefail

REPO="${DALA_REPO:-mjason/dala}"
ROOT="${DALA_HOME:-$HOME/.local/dala}"
SERVICE="dala"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -e "$ROOT/current" ] || die "no existing install at $ROOT — run install.sh first"

CURRENT=$(basename "$(readlink -f "$ROOT/current")")

TAG="${1:-}"
if [ -z "$TAG" ]; then
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
    grep -m1 '"tag_name"' | cut -d'"' -f4) || true
  [ -n "$TAG" ] || die "could not resolve the latest release"
fi

if [ "$TAG" = "$CURRENT" ]; then
  say "already on $TAG — nothing to do"
  exit 0
fi

ASSET="dala-$TAG-linux-x86_64.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
DEST="$ROOT/versions/$TAG"

if [ ! -x "$DEST/bin/dala" ]; then
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

say "switching $CURRENT → $TAG"
ln -sfn "$DEST" "$ROOT/current"
# ExecStartPre migrates the database before the new version boots.
systemctl --user restart "$SERVICE"

ls -1dt "$ROOT"/versions/* 2>/dev/null | tail -n +4 | while read -r old; do
  [ "$old" = "$DEST" ] && continue
  say "pruning $(basename "$old")"
  rm -rf "$old"
done

say "updated to $TAG (shells kept running)"
