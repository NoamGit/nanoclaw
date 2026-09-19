#!/bin/bash
# start-nanoclaw.sh — start (or restart) the NanoClaw host without systemd.
# Called by /home/nanoclaw/bin/recover-after-shutdown.sh; safe to run by hand.
#
#   1. stop any running instance (found by cwd + entrypoint, however it was started)
#   2. apply ops/mcp-wiring.json to the DB (idempotent, non-fatal)
#   3. start dist/index.js, write nanoclaw.pid
#
# To stop:  kill "$(cat /home/nanoclaw/nanoclaw-v2/nanoclaw.pid)"

set -euo pipefail

ROOT="/home/nanoclaw/nanoclaw-v2"
NODE="/home/nanoclaw/.nvm/versions/node/v22.22.2/bin/node"
export DOCKER_HOST="unix:///run/user/1002/docker.sock"
export XDG_RUNTIME_DIR="/run/user/1002"

cd "$ROOT"
mkdir -p logs

[ -f dist/index.js ] || { echo "dist/index.js missing — run: pnpm run build" >&2; exit 1; }

# PIDs of host instances running from this checkout (pid file or hand-started).
running_pids() {
  local p
  for p in $(pgrep -x node 2>/dev/null || true); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null || true)" = "$ROOT" ] || continue
    tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q 'dist/index.js' && echo "$p"
  done
}

OLD="$(running_pids | tr '\n' ' ')"
if [ -n "${OLD// /}" ]; then
  echo "Stopping existing NanoClaw (PID ${OLD})..."
  kill $OLD 2>/dev/null || true
  for _ in $(seq 1 30); do
    [ -z "$(running_pids)" ] && break
    sleep 1
  done
  if [ -n "$(running_pids)" ]; then
    echo "Existing NanoClaw did not stop within 30s — not starting a second instance." >&2
    exit 1
  fi
fi

echo "Applying MCP wiring..."
"$ROOT/node_modules/.bin/tsx" ops/apply-mcp-wiring.ts || echo "WARNING: MCP wiring step failed (continuing)" >&2

echo "Starting NanoClaw..."
nohup "$NODE" "$ROOT/dist/index.js" \
  >> "$ROOT/logs/nanoclaw.log" \
  2>> "$ROOT/logs/nanoclaw.error.log" &
echo $! > "$ROOT/nanoclaw.pid"

sleep 3
if kill -0 "$(cat "$ROOT/nanoclaw.pid")" 2>/dev/null; then
  echo "NanoClaw started (PID $(cat "$ROOT/nanoclaw.pid"))"
  echo "Logs: tail -f $ROOT/logs/nanoclaw.log"
else
  echo "NanoClaw exited right after start — see $ROOT/logs/nanoclaw.error.log" >&2
  exit 1
fi
