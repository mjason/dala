#!/usr/bin/env bash
# Playwright webServer entry: boots a throwaway dala dev server on :4499,
# FULLY isolated from the developer's real dala instance:
#
# - sqlite: sessions live in dala_dev.db (DALA_DATA_DIR does NOT move the
#   database). We copy the dev DB into the workdir (schema included), purge
#   terminal_sessions and user-created themes IN THE COPY, so the e2e server
#   never sees real sessions and visual theme snapshots have fixed inputs.
# - PTY holders: shells outlive dala restarts via holder sockets under
#   $XDG_RUNTIME_DIR/dala-pty. A private XDG_RUNTIME_DIR keeps e2e holders
#   away from the user's live shells (a shared dir would let the e2e server
#   attach to real session holders and kick the real client).
# - DALA_DATA_DIR: still set for good measure (historic DETS isolation).
#
# The database override has no env hook in config/dev.exs, so the server is
# started via `mix run --no-start` with an Application.put_env prelude
# instead of `mix phx.server` — no application code or config is modified.
set -euo pipefail

cd ..

# Housekeeping: previous runs leave /tmp/dala-e2e-* workdirs behind (the
# script is SIGKILLed by Playwright, so no exit trap can clean up). Reap
# leftover e2e holder shells (ONLY ones whose socket lives under an e2e
# workdir — never the user's real holders) and day-old workdirs.
pgrep -f 'dala_holder.*"socket":"/tmp/dala-e2e-' | xargs -r kill 2>/dev/null || true
find /tmp -maxdepth 1 -name 'dala-e2e-*' -mmin +120 -user "$(id -un)" -exec rm -rf {} + 2>/dev/null || true

WORK=$(mktemp -d /tmp/dala-e2e-XXXX)
export XDG_RUNTIME_DIR="$WORK/runtime"
export DALA_DATA_DIR="$WORK/data"
mkdir -p "$XDG_RUNTIME_DIR" "$DALA_DATA_DIR"

# CI has no developer database — create one (schema + seeds) on first run.
[ -f dala_dev.db ] || mix ecto.setup

export DALA_E2E_DB="$WORK/dala_e2e.db"
sqlite3 dala_dev.db ".backup '$DALA_E2E_DB'"
sqlite3 "$DALA_E2E_DB" "DELETE FROM terminal_sessions; DELETE FROM custom_themes WHERE builtin = 0; DELETE FROM prompt_stash;"

export PORT=4499

exec mix run --no-halt --no-start -e '
  db = System.fetch_env!("DALA_E2E_DB")

  repo = Application.get_env(:dala, Dala.Repo) |> Keyword.put(:database, db)
  Application.put_env(:dala, Dala.Repo, repo)

  endpoint = Application.get_env(:dala, DalaWeb.Endpoint) |> Keyword.put(:server, true)
  Application.put_env(:dala, DalaWeb.Endpoint, endpoint)

  {:ok, _} = Application.ensure_all_started(:dala)
'
