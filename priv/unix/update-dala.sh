#!/bin/sh
set -u

INSTALL_ROOT=${1:?install root is required}
SERVICE_MANAGER=${2:?service manager is required}
SERVICE_NAME=${3:?service name is required}
TARGET_TAG=${4:?target tag is required}
PREVIOUS_TAG=${5:?previous tag is required}
EXPECTED_VERSION=${6:?expected version is required}
PREVIOUS_VERSION=${7:?previous version is required}
ATTEMPT_ID=${8:?attempt id is required}
RESULT_FILE=${9:?result file is required}
HEALTH_URL=${10:?health URL is required}
HEALTH_ATTEMPTS=${11:-60}
HEALTH_DELAY_SECONDS=${12:-0.5}

umask 077

LOCK_DIR="$INSTALL_ROOT/.update-dala.lock"
LOCK_HELD=0
CURRENT_FRESH=""

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -z "$owner" ] || [ "$owner" = "$$" ]; then
      rm -f "$LOCK_DIR/pid"
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    LOCK_HELD=0
  fi

  if [ -n "$CURRENT_FRESH" ]; then
    rm -f "$CURRENT_FRESH"
    CURRENT_FRESH=""
  fi
}

on_signal() {
  release_lock
  exit 1
}

trap release_lock 0
trap on_signal HUP INT TERM

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_result() {
  success=$1
  rolled_back=$2
  message=$3
  result_dir=$(dirname "$RESULT_FILE")
  fresh="$RESULT_FILE.new-$$"
  completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  mkdir -p "$result_dir" || return 1

  printf '{"attempt_id":"%s","success":%s,"rolled_back":%s,"target":"%s","previous":"%s","message":"%s","completed_at":"%s"}\n' \
    "$(json_escape "$ATTEMPT_ID")" \
    "$success" \
    "$rolled_back" \
    "$(json_escape "$TARGET_TAG")" \
    "$(json_escape "$PREVIOUS_TAG")" \
    "$(json_escape "$message")" \
    "$completed_at" > "$fresh" || return 1

  mv -f "$fresh" "$RESULT_FILE"
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    # Mark ownership before writing the pid so a signal between these two
    # operations still removes the directory lock.
    LOCK_HELD=1
    if printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
      return 0
    fi

    release_lock
    return 2
  fi

  # A detached helper can be killed while holding the directory lock. Reap a
  # lock whose recorded owner is definitely gone, but never remove a live
  # owner's lock. The mkdir itself remains the inter-process atomic primitive.
  if [ -d "$LOCK_DIR" ]; then
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9]*)
        return 1
        ;;
      *)
        if kill -0 "$owner" 2>/dev/null; then
          return 1
        fi

        rm -f "$LOCK_DIR/pid"
        if rmdir "$LOCK_DIR" 2>/dev/null; then
          acquire_lock
        else
          return 1
        fi
        ;;
    esac
  else
    return 2
  fi
}

acquire_lock
lock_status=$?
if [ "$lock_status" -ne 0 ]; then
  if [ "$lock_status" -eq 1 ]; then
    write_result false false "another update is already in progress"
  else
    write_result false false "could not acquire update lock"
  fi
  exit 1
fi

current_tag() {
  target=$(readlink "$INSTALL_ROOT/current") || return 1
  basename "$target"
}

switch_current() {
  tag=$1
  destination="$INSTALL_ROOT/versions/$tag"
  [ -d "$destination" ] || return 1
  CURRENT_FRESH="$INSTALL_ROOT/.current.new-$$"
  rm -f "$CURRENT_FRESH"
  ln -s "$destination" "$CURRENT_FRESH" || {
    rm -f "$CURRENT_FRESH"
    CURRENT_FRESH=""
    return 1
  }

  # `ln -sfn` unlinks the old link before creating the new one. Replace the
  # directory entry with rename(2) instead, so readers see either complete
  # pointer and never an absent `current`. GNU mv needs -T; BSD-family mv
  # uses -h to avoid following the destination symlink.
  case "$(uname -s 2>/dev/null || printf unknown)" in
    Darwin|FreeBSD|NetBSD|OpenBSD|DragonFly)
      mv -fh "$CURRENT_FRESH" "$INSTALL_ROOT/current"
      ;;
    *)
      mv -Tf "$CURRENT_FRESH" "$INSTALL_ROOT/current"
      ;;
  esac
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -f "$CURRENT_FRESH"
    CURRENT_FRESH=""
    return "$status"
  fi

  CURRENT_FRESH=""
  return 0
}

restart_service() {
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl --user restart --no-block "$SERVICE_NAME"
      ;;
    launchd)
      launchctl kickstart -k "gui/$(id -u)/$SERVICE_NAME"
      ;;
    *)
      return 2
      ;;
  esac
}

healthy() {
  expected=$1
  expected_tag=$2
  [ "$(current_tag 2>/dev/null)" = "$expected_tag" ] || return 1
  actual=$(curl --fail --silent --show-error --max-time 2 "$HEALTH_URL" 2>/dev/null) || return 1
  [ "$actual" = "$expected" ]
}

wait_healthy() {
  expected=$1
  expected_tag=$2
  attempt=0

  while [ "$attempt" -lt "$HEALTH_ATTEMPTS" ]; do
    if healthy "$expected" "$expected_tag"; then
      return 0
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -lt "$HEALTH_ATTEMPTS" ] && [ "$HEALTH_DELAY_SECONDS" != "0" ]; then
      sleep "$HEALTH_DELAY_SECONDS"
    fi
  done

  return 1
}

rollback() {
  failure=$1

  if [ "$(current_tag 2>/dev/null)" != "$TARGET_TAG" ]; then
    write_result false false "$failure; rollback skipped because the current release changed"
    return 1
  fi

  if switch_current "$PREVIOUS_TAG" && restart_service &&
      wait_healthy "$PREVIOUS_VERSION" "$PREVIOUS_TAG"; then
    write_result false true "$failure; rolled back to $PREVIOUS_TAG"
  else
    write_result false false "$failure; rollback did not restore $PREVIOUS_TAG"
  fi

  return 1
}

initial_delay=${DALA_UPDATE_DELAY_SECONDS:-0.75}
if [ "$initial_delay" != "0" ]; then
  sleep "$initial_delay"
fi

if [ "$(current_tag 2>/dev/null)" != "$PREVIOUS_TAG" ]; then
  write_result false false "current release changed before update activation"
  exit 1
fi

if ! switch_current "$TARGET_TAG"; then
  write_result false false "could not switch current release to $TARGET_TAG"
  exit 1
fi

if ! restart_service; then
  rollback "service manager rejected restart for $TARGET_TAG"
  exit 1
fi

if wait_healthy "$EXPECTED_VERSION" "$TARGET_TAG"; then
  write_result true false "updated to $TARGET_TAG"
  exit 0
fi

rollback "Dala $EXPECTED_VERSION did not become healthy"
exit 1
