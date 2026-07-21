#!/usr/bin/env bash
set -euo pipefail

release_dir="${1:-_build/prod/rel/dala}"
release_dir="$(cd "$release_dir" && pwd)"
release_bin="$release_dir/bin/dala"

if [[ ! -x "$release_bin" ]]; then
  echo "Release is missing executable bin/dala: $release_dir" >&2
  exit 1
fi

smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/dala-release-smoke.XXXXXX")"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    "$release_bin" stop >/dev/null 2>&1 || kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$smoke_root"
}
trap cleanup EXIT

port="$(node -e 'const net=require("net");const s=net.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
mkdir -p "$smoke_root/data"

export PHX_SERVER=true
export PORT="$port"
export PHX_HOST=localhost
export PHX_CHECK_ORIGIN=false
export DALA_LISTEN_IP=127.0.0.1
export DATABASE_PATH="$smoke_root/data/dala.db"
export DALA_DATA_DIR="$smoke_root/data"
export RELEASE_NODE="dala_smoke_$$"
export RELEASE_COOKIE="dala_smoke_cookie_$$"
export SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
export TOKEN_SIGNING_SECRET=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789

"$release_bin" eval 'Dala.Release.migrate()'
"$release_bin" start >"$smoke_root/server.log" 2>&1 &
server_pid=$!

http_status=""
for _attempt in {1..60}; do
  http_status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/" || true)"
  if [[ "$http_status" =~ ^[234][0-9][0-9]$ ]]; then
    break
  fi
  sleep 0.5
done

if [[ ! "$http_status" =~ ^[234][0-9][0-9]$ ]]; then
  cat "$smoke_root/server.log" >&2
  echo "Dala did not become healthy on port $port" >&2
  exit 1
fi

rpc_output="$("$release_bin" rpc 'IO.puts("DALA_RELEASE_SMOKE_RPC")')"
if [[ "$rpc_output" != *DALA_RELEASE_SMOKE_RPC* ]]; then
  echo "Release RPC probe failed: $rpc_output" >&2
  exit 1
fi

"$release_bin" stop
for _attempt in {1..100}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if kill -0 "$server_pid" 2>/dev/null; then
  echo "Release process did not stop" >&2
  exit 1
fi

wait "$server_pid" 2>/dev/null || true
server_pid=""
printf '{"http_status":%s,"rpc":true,"stopped":true}\n' "$http_status"
