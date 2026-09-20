#!/bin/bash
# recover-after-shutdown.sh — bring the whole NanoClaw stack back after a power
# cut, reboot or crash. Every step is idempotent, so it is safe to re-run.
#
#   recover-after-shutdown.sh            full recovery
#   recover-after-shutdown.sh --check    READ-ONLY diagnosis: changes nothing, exit 0 = healthy
#   recover-after-shutdown.sh --ensure   watchdog mode for cron: exit 0 quietly if NanoClaw is
#                                        running, otherwise run the full recovery, then send a
#                                        Telegram alert (restarted / restart FAILED). Guarded by a
#                                        lock (no overlapping runs) and a crash-loop limit (at most
#                                        3 auto-recoveries per 30 min, then it alerts and backs off).
#
# Canonical copy lives in the repo (ops/); /home/nanoclaw/bin/recover-after-shutdown.sh is a symlink.
# Exit: 0 = everything healthy, 1 = finished but with warnings (or aborted), 2 = bad usage.
# Log:  /home/nanoclaw/nanoclaw-v2/logs/recovery.log (full recovery / --ensure only)

set -uo pipefail

NC="/home/nanoclaw/nanoclaw-v2"
export DOCKER_HOST="unix:///run/user/1002/docker.sock"
export XDG_RUNTIME_DIR="/run/user/1002"
# Explicit PATH: cron / boot-time shells do not have ~/bin (docker) or nvm's node.
export PATH="/home/nanoclaw/bin:/home/nanoclaw/.local/bin:/home/nanoclaw/.nvm/versions/node/v22.22.2/bin:$PATH"

ONECLI_URL="${ONECLI_URL:-http://172.17.0.1:10254}"
BACKUP_STATUS="/home/nanoclaw/backups/.last-backup-v2-ok"
DISK_WARN_PCT=85
ALERT_ENV="${NANOCLAW_ALERT_ENV:-/home/nanoclaw/.config/nanoclaw/alert.env}"
MAX_AUTO_RECOVERIES=3   # per 30 minutes, --ensure mode only

MODE=recover
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --ensure) MODE=ensure ;;
  *) echo "usage: $0 [--check | --ensure]" >&2; exit 2 ;;
esac

WARNINGS=0
log()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "  ok: $*"; }
warn() { echo "  WARNING: $*"; WARNINGS=$((WARNINGS + 1)); }
# Run a mutating action; in --check mode only say what would happen.
act()  { local d="$1"; shift; if [ "$MODE" = check ]; then echo "  (check) would: $d"; else "$@"; fi; }
# wait_for <timeout-seconds> <cmd...> : poll until cmd succeeds
wait_for() { local t="$1" i; shift; for ((i = 0; i < t; i += 2)); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

# Telegram alert (same channel as nanoclaw-cleanup.sh). Never fails the caller.
alert() {
  echo "  ALERT: $*"
  [ -r "$ALERT_ENV" ] || return 0
  ( . "$ALERT_ENV"
    [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || exit 0
    curl -s -m 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT_ID" --data-urlencode text="nanoclaw watchdog: $*" >/dev/null ) || true
}

nanoclaw_pids() {  # host instances running from this checkout (hand-started or via start-nanoclaw.sh)
  local p
  for p in $(pgrep -x node 2>/dev/null || true); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null || true)" = "$NC" ] || continue
    tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q 'dist/index.js' && echo "$p"
  done
}

if [ "$MODE" = ensure ] && [ -n "$(nanoclaw_pids)" ]; then
  exit 0
fi
if [ "$MODE" != check ]; then
  mkdir -p "$NC/logs"
  # One recovery at a time: a full run can outlast the next 5-minute cron tick.
  exec 9>"$NC/logs/.recovery.lock"
  if ! flock -n 9; then
    [ "$MODE" = ensure ] && exit 0
    echo "Another recovery run is already in progress (lock: $NC/logs/.recovery.lock)." >&2
    exit 1
  fi
  exec > >(tee -a "$NC/logs/recovery.log") 2>&1
  echo; echo "##### recovery run $(date '+%F %T') (mode: $MODE) #####"
fi

if [ "$MODE" = ensure ]; then
  # Crash-loop guard: if NanoClaw keeps dying right after we restart it, more
  # restarts will not help. Back off and tell a human instead of looping forever.
  ATTEMPTS="$NC/logs/.ensure-attempts"; SUSPEND_MARK="$NC/logs/.ensure-suspended"
  NOW=$(date +%s)
  RECENT=$(awk -v n="$NOW" '$1 > n - 1800' "$ATTEMPTS" 2>/dev/null)
  COUNT=$(printf '%s' "$RECENT" | grep -c . || true)
  if [ "$COUNT" -ge "$MAX_AUTO_RECOVERIES" ]; then
    echo "  NanoClaw is down but $COUNT auto-recoveries already ran in the last 30 min — backing off."
    if [ ! -f "$SUSPEND_MARK" ] || [ $((NOW - $(stat -c %Y "$SUSPEND_MARK"))) -gt 1800 ]; then
      touch "$SUSPEND_MARK"
      alert "NanoClaw keeps going down: $COUNT auto-restarts in 30 min, auto-restart SUSPENDED. Investigate: logs/nanoclaw.error.log and logs/recovery.log, then run recover-after-shutdown.sh by hand."
    fi
    exit 1
  fi
  printf '%s\n%s\n' "$RECENT" "$NOW" | grep . > "$ATTEMPTS"
  ensure_report() {  # runs on every exit path once the guard has passed
    local rc=$?
    if [ -n "$(nanoclaw_pids)" ]; then
      alert "NanoClaw was DOWN and has been auto-restarted (recovery exit $rc; warnings: $WARNINGS). Details: logs/recovery.log"
    else
      alert "NanoClaw is DOWN and the auto-restart FAILED (recovery exit $rc). Details: logs/recovery.log"
    fi
  }
  trap ensure_report EXIT
fi
[ "$MODE" = check ] && echo "##### READ-ONLY CHECK — nothing will be changed #####"

# ─── 1. Rootless Docker daemon ──────────────────────────────────────────
log "Docker daemon"
if ! docker info >/dev/null 2>&1; then
  if [ "$MODE" = check ]; then
    warn "Docker daemon not reachable at $DOCKER_HOST"
  else
    echo "  not reachable — starting it..."
    systemctl --user start docker 2>/dev/null || nohup /home/nanoclaw/bin/dockerd-rootless.sh >/tmp/dockerd-rootless.log 2>&1 &
    wait_for 60 docker info || true
    docker info >/dev/null 2>&1 || { echo "  Docker failed to start — aborting."; exit 1; }
    ok "Docker started"
  fi
else
  ok "Docker is up"
fi
if ! docker info >/dev/null 2>&1; then echo "Cannot continue without Docker."; exit 1; fi

# ─── 2. Disk space ──────────────────────────────────────────────────────
# A full disk corrupts SQLite session DBs and breaks image builds. Pruning is
# delegated to nanoclaw-cleanup.sh, which refuses to prune unless a verified
# recent backup exists (this script used to prune the build cache unconditionally).
log "Disk space"
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
FREE=$(df -h --output=avail / | tail -1 | tr -d ' ')
if [ "$USED" -ge "$DISK_WARN_PCT" ]; then
  warn "/ is ${USED}% full (${FREE} free)"
  act "run nanoclaw-cleanup.sh watchdog" /home/nanoclaw/bin/nanoclaw-cleanup.sh watchdog || true
else
  ok "/ is ${USED}% full (${FREE} free)"
fi

# ─── 3. OneCLI + postgres ───────────────────────────────────────────────
log "OneCLI + postgres (docker compose)"
if [ "$MODE" = check ]; then
  echo "  (check) would: docker compose up -d in /home/nanoclaw/.onecli"
else
  ( cd /home/nanoclaw/.onecli && docker compose up -d ) || warn "docker compose up failed"
fi
pg_healthy() { [ "$(docker inspect onecli-postgres-1 --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ]; }
wait_for 60 pg_healthy \
  && ok "onecli-postgres-1 healthy" || warn "onecli-postgres-1 is not healthy"

# ─── 4. Rootless-Docker network bug ─────────────────────────────────────
# After a power cut, containers can come back with NO network attached
# (rootlesskit/slirp4netns loses its state). Reconnect any that did.
log "Container networking"
fix_network() {  # fix_network <container> <net>[:<alias>]...
  local name="$1"; shift
  docker inspect "$name" >/dev/null 2>&1 || { warn "$name does not exist"; return; }
  local n; n=$(docker inspect "$name" --format '{{len .NetworkSettings.Networks}}' 2>/dev/null || echo 0)
  if [ "$n" != "0" ]; then ok "$name network attached"; return; fi
  warn "$name has NO network attached"
  local spec net alias
  for spec in "$@"; do
    net="${spec%%:*}"; alias=""; [ "$spec" != "$net" ] && alias="${spec#*:}"
    if [ "$MODE" = check ]; then echo "  (check) would: docker network connect $net $name"; continue; fi
    if [ -n "$alias" ]; then docker network connect "$net" "$name" --alias "$alias"; else docker network connect "$net" "$name"; fi \
      && echo "  reconnected $name -> $net"
  done
}
fix_network onecli-postgres-1 onecli_onecli:postgres
fix_network onecli onecli_onecli
fix_network bank-mcp-server bank-assistant-network onecli_onecli
fix_network nanoclaw-squid onecli_onecli

# ─── 5. Sibling containers (restart policies) + gateway readiness ───────
# The daemon should bring these back by itself; verify and nudge. NanoClaw
# refuses to spawn agent containers until the OneCLI gateway answers, so wait for it.
log "Sibling containers + OneCLI gateway"
for name in onecli bank-mcp-server nanoclaw-squid; do
  state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [ "$state" = running ]; then ok "$name running"; continue; fi
  warn "$name is $state"
  act "docker start $name" docker start "$name" || warn "could not start $name"
done
if wait_for 90 curl -sf -m 5 "$ONECLI_URL/api/apps" -o /dev/null; then
  ok "OneCLI API answering at $ONECLI_URL"
else
  warn "OneCLI API not answering at $ONECLI_URL — agents cannot start without it"
fi

# Human-in-the-loop: the gateway HOLDS gated requests (Gmail send/delete, Drive delete) until
# NanoClaw shows you an approval card. NanoClaw finds the gateway via ONECLI_GATEWAY_URL in .env
# (else the URL the web app advertises, http://localhost:10255 — refused on this host). If it
# cannot poll, held requests are silently denied after the TTL and no card ever arrives.
GW_URL=$(grep -s '^ONECLI_GATEWAY_URL=' "$NC/.env" | cut -d= -f2-)
[ -n "$GW_URL" ] || GW_URL=$(curl -s -m 5 "$ONECLI_URL/api/gateway-url" | python3 -c 'import sys,json; print(json.load(sys.stdin)["url"])' 2>/dev/null)
curl -s -m 3 -o /dev/null "${GW_URL:-http://localhost:10255}/api/approvals/pending"; RC=$?
# exit 28 = connected and the long-poll was held open (healthy); 0 = answered; anything else = unreachable
if [ "$RC" = 0 ] || [ "$RC" = 28 ]; then
  ok "approval channel reachable (${GW_URL})"
else
  warn "approval channel UNREACHABLE at ${GW_URL:-http://localhost:10255} (curl $RC) — approval cards would never arrive; set ONECLI_GATEWAY_URL in $NC/.env"
fi
python3 "$NC/ops/apply-hitl-rules.py" --check >/tmp/hitl-check.$$ 2>&1 \
  && ok "human-approval rules in sync ($(grep -c ': ok' /tmp/hitl-check.$$) rules)" \
  || { warn "human-approval rules missing/out of sync — re-apply with: python3 $NC/ops/apply-hitl-rules.py"; sed 's/^/    /' /tmp/hitl-check.$$; }
rm -f /tmp/hitl-check.$$

# ─── 6. Preflight for NanoClaw itself ───────────────────────────────────
log "NanoClaw preflight"
DB_OK=1
DB_RESULT=$(python3 - "$NC/data/v2.db" <<'PY' 2>&1
import sqlite3, sys
try:
    c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=10)
    r = c.execute("PRAGMA quick_check").fetchone()[0]
except Exception as e:
    r = str(e)
print(r)
sys.exit(0 if r == "ok" else 1)
PY
) || DB_OK=0
if [ "$DB_OK" = 1 ]; then
  ok "data/v2.db integrity ok"
else
  warn "data/v2.db FAILED its integrity check: ${DB_RESULT:0:200}"
  if [ -r "$BACKUP_STATUS" ]; then
    echo "  latest verified backup: $(cut -d' ' -f2 "$BACKUP_STATUS")"
    echo "  restore data/v2.db from it (tar xzf <archive> data/v2.db) after stopping NanoClaw."
  fi
fi

IMAGE=$(bash -c "PROJECT_ROOT='$NC'; source '$NC/setup/lib/install-slug.sh'; container_image_base" 2>/dev/null)
if docker image inspect "${IMAGE}:latest" >/dev/null 2>&1; then
  ok "agent image ${IMAGE}:latest present"
else
  warn "agent image ${IMAGE}:latest is missing — run: cd $NC && ./container/build.sh"
fi

if [ ! -f "$NC/dist/index.js" ]; then
  warn "dist/index.js missing — run: cd $NC && pnpm run build"
elif [ -n "$(find "$NC/src" -name '*.ts' -newer "$NC/dist/index.js" 2>/dev/null | head -1)" ]; then
  warn "src/ is newer than dist/index.js (stale build) — consider: cd $NC && pnpm run build"
else
  ok "dist/ is up to date with src/"
fi

# ─── 7. NanoClaw host process ───────────────────────────────────────────
log "NanoClaw host process"
if [ "$MODE" = check ]; then
  PIDS=$(nanoclaw_pids | tr '\n' ' ')
  if [ -n "${PIDS// /}" ]; then ok "running (PID ${PIDS})"; else warn "NanoClaw is NOT running"; echo "  (check) would: bash start-nanoclaw.sh"; fi
elif [ "$DB_OK" != 1 ]; then
  echo "  NOT starting NanoClaw: its database failed the integrity check (see above)."
  warn "NanoClaw left stopped — fix data/v2.db first, then re-run this script"
else
  LOG_LINES=$(wc -l < "$NC/logs/nanoclaw.log" 2>/dev/null || echo 0)
  bash "$NC/start-nanoclaw.sh" || warn "start-nanoclaw.sh failed"
  # Only look at lines written AFTER the start, so an old "running" line can't false-pass.
  if wait_for 30 bash -c "tail -n +$((LOG_LINES + 1)) '$NC/logs/nanoclaw.log' | grep -q 'NanoClaw running'"; then
    ok "NanoClaw reports it is running"
  else
    warn "NanoClaw did not report 'running' within 30s — check logs/nanoclaw.error.log"
  fi
fi

# ─── 8. Google MCPs (Gmail / Calendar / Drive) ──────────────────────────
# start-nanoclaw.sh re-applied ops/mcp-wiring.json. Prove each MCP works end to
# end (one real read-only call through OneCLI) so an expired Google connection
# or disabled API is surfaced here rather than as a silent failure in chat.
log "Google MCPs (gmail / calendar / drive)"
python3 "$NC/ops/mcp-health.py" && ok "all Google MCPs healthy" \
  || warn "a Google MCP is unhealthy — see above (reconnect the app in the OneCLI UI, or enable the API in Google Cloud)"

# ─── 9. Bank scraper catch-up ───────────────────────────────────────────
# If the last successful scrape is >30h old (the 06:00 cron was missed during
# the outage), catch up now rather than waiting until tomorrow.
log "Bank scraper freshness"
LAST_SUCCESS=$(docker run --rm -v financial-mcp_bank-data:/data:ro alpine sh -c \
  "apk add --quiet sqlite 2>/dev/null && sqlite3 /data/bank.db \"SELECT completed_at FROM scrape_runs WHERE status='completed' ORDER BY completed_at DESC LIMIT 1;\"" \
  2>/dev/null || echo "")
IS_STALE=yes
if [ -n "$LAST_SUCCESS" ]; then
  IS_STALE=$(LAST_SUCCESS="$LAST_SUCCESS" python3 - <<'PY'
import os
from datetime import datetime, timezone, timedelta
ts = os.environ.get("LAST_SUCCESS", "").strip()
try:
    last = datetime.fromisoformat(ts.replace(" ", "T")).replace(tzinfo=timezone.utc)
    print("yes" if (datetime.now(timezone.utc) - last) > timedelta(hours=30) else "no")
except Exception:
    print("yes")
PY
)
fi
if [ "$IS_STALE" = no ]; then
  ok "last scrape $LAST_SUCCESS — fresh"
else
  warn "bank scrape is stale (last success: ${LAST_SUCCESS:-none recorded})"
  if [ "$MODE" = check ]; then
    echo "  (check) would: run financial-mcp/scripts/run-scrape.sh"
  else
    bash /home/nanoclaw/financial-mcp/scripts/run-scrape.sh >> /home/nanoclaw/financial-mcp/logs/scraper.log 2>&1 \
      && echo "  catch-up scrape completed" \
      || warn "catch-up scrape failed — see /home/nanoclaw/financial-mcp/logs/scraper.log"
  fi
fi

# ─── 10. Summary ────────────────────────────────────────────────────────
log "Summary"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo
PIDS=$(nanoclaw_pids | tr '\n' ' ')
if [ -n "${PIDS// /}" ]; then echo "NanoClaw running (PID ${PIDS})"; else echo "NanoClaw NOT running"; fi
echo "Logs: tail -f $NC/logs/nanoclaw.log   (errors: $NC/logs/nanoclaw.error.log)"
if [ "$WARNINGS" -eq 0 ]; then
  echo "RESULT: all checks passed."
  exit 0
fi
echo "RESULT: finished with $WARNINGS warning(s) — see WARNING lines above."
exit 1
