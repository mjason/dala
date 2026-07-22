#!/usr/bin/env bash
#
# Dala updater - downloads the native release for this machine, switches the
# current symlink and restarts the user daemon.
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/update.sh | bash
#   ./update.sh [vX.Y.Z]
set -euo pipefail

REPO="${DALA_REPO:-mjason/dala}"
ROOT="${DALA_HOME:-$HOME/.local/dala}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

verify_checksum() {
  checksum_file=$1
  archive=$2
  asset=$3

  # Release checksums are a one-line sha256sum record. Reject missing,
  # ambiguous, or differently named records before invoking the checker so a
  # valid checksum for another file cannot authorize this archive.
  parsed=$(awk '
    { count++ }
    NF == 2 {
      name = $2
      sub(/^\*/, "", name)
      sub(/\r$/, "", name)
      print $1 "\t" name
      valid++
    }
    END { if (count != 1 || valid != 1) exit 1 }
  ' "$checksum_file") || die "malformed checksum for $asset"

  expected_hash=${parsed%%$'\t'*}
  expected_name=${parsed#*$'\t'}
  printf '%s\n' "$expected_hash" | grep -Eq '^[[:xdigit:]]{64}$' ||
    die "malformed checksum for $asset"
  [ "$expected_name" = "$asset" ] || die "checksum names unexpected asset"

  if [ "$PLATFORM" = "macos-arm64" ]; then
    (cd "$(dirname "$archive")" && shasum -a 256 -c "$(basename "$checksum_file")" >/dev/null) ||
      die "checksum mismatch"
  else
    (cd "$(dirname "$archive")" && sha256sum -c -- "$(basename "$checksum_file")" >/dev/null) ||
      die "checksum mismatch"
  fi
}

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)
    PLATFORM="linux-x86_64"
    SERVICE_MANAGER="systemd"
    SERVICE_NAME="${DALA_SERVICE:-dala}"
    ;;
  Darwin/arm64)
    PLATFORM="macos-arm64"
    SERVICE_MANAGER="launchd"
    SERVICE_NAME="${DALA_SERVICE:-com.manjialin.dala}"
    ;;
  *) die "no prebuilt release for $(uname -s)/$(uname -m)" ;;
esac

[ -e "$ROOT/current" ] || die "no existing install at $ROOT - run install.sh first"
CURRENT=$(basename "$(cd "$ROOT/current" && pwd -P)")

TAG="${1:-}"
if [ -z "$TAG" ]; then
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=15" |
    grep '"tag_name"' | cut -d'"' -f4 | grep -m1 '^v[0-9]') || true
  [ -n "$TAG" ] || die "could not resolve the latest release"
fi

if [ "$TAG" = "$CURRENT" ]; then
  say "already on $TAG - nothing to do"
  exit 0
fi

ASSET="dala-$TAG-$PLATFORM.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
DEST="$ROOT/versions/$TAG"

if [ ! -x "$DEST/bin/dala" ]; then
  say "downloading $ASSET"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fSL --progress-bar -o "$TMP/$ASSET" "$URL"
  curl -fsSL -o "$TMP/$ASSET.sha256" "$URL.sha256" 2>/dev/null ||
    die "could not download checksum for $ASSET"
  verify_checksum "$TMP/$ASSET.sha256" "$TMP/$ASSET" "$ASSET"
  say "checksum ok"
  mkdir -p "$DEST"
  tar -xzf "$TMP/$ASSET" -C "$DEST"
fi

say "switching $CURRENT -> $TAG"
ln -sfn "$DEST" "$ROOT/current"

if [ "$SERVICE_MANAGER" = "systemd" ]; then
  # ExecStartPre migrates the database before the new version boots.
  systemctl --user restart "$SERVICE_NAME"
else
  launchctl kickstart -k "gui/$(id -u)/$SERVICE_NAME"
fi

ls -1dt "$ROOT"/versions/* 2>/dev/null | tail -n +4 | while read -r old; do
  [ "$old" = "$DEST" ] && continue
  say "pruning $(basename "$old")"
  rm -rf "$old"
done

say "updated to $TAG (shells kept running)"
