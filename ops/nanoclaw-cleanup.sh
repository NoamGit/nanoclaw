#!/bin/bash
# nanoclaw disk hygiene. Never touches data/, groups/, Docker volumes, or bind-mounted state.
#   nanoclaw-cleanup.sh daily      [--dry-run]   Docker dangling images, build cache (keep 2GB), stopped containers
#   nanoclaw-cleanup.sh weekly     [--dry-run]   package caches, old Claude CLI versions, log rotation
#   nanoclaw-cleanup.sh watchdog   [--dry-run]   if / is >= WARN_PCT: emergency prune + Telegram alert
#   nanoclaw-cleanup.sh status                   disk + reclaimable summary, changes nothing
# Deliberately NOT used: `docker image prune -a` (would delete financial-mcp-scraper), `docker volume prune`.
set -uo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

MODE="${1:-status}"; DRY=0; [ "${2:-}" = "--dry-run" ] && DRY=1
WARN_PCT="${WARN_PCT:-90}"; CRIT_PCT="${CRIT_PCT:-95}"     # override in ops.env
ALERT_COOLDOWN_H="${ALERT_COOLDOWN_H:-6}"; ALERT_MIN_FREED_MB="${ALERT_MIN_FREED_MB:-1024}"
ALERT_STATE="$BACKUP_DIR/.last-disk-alert"
KEEP_CACHE="2GB"
BACKUP_STATUS="$BACKUP_STATUS_FILE"
LOGDIR="$NANOCLAW_HOME/logs"

log() { echo "[$(date '+%F %T')] $*"; }
run() { if [ $DRY -eq 1 ]; then log "DRY: $*"; else log "RUN: $*"; "$@" 2>&1 | sed 's/^/    /'; fi; }
used_pct() { df --output=pcent / | tail -1 | tr -dc '0-9'; }
free_h() { df -h --output=avail / | tail -1 | tr -d ' '; }

alert() {  # throttled: at most one Telegram message per ALERT_COOLDOWN_H
  log "ALERT: $*"
  if [ -r "$ALERT_STATE" ] && [ $(( $(date +%s) - $(cat "$ALERT_STATE") )) -lt $(( ALERT_COOLDOWN_H * 3600 )) ]; then
    log "alert suppressed (cooldown ${ALERT_COOLDOWN_H}h)"; return 0
  fi
  [ $DRY -eq 1 ] || date +%s > "$ALERT_STATE"
  [ -r "$ALERT_ENV" ] || return 0
  # shellcheck disable=SC1090
  . "$ALERT_ENV"
  [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0
  [ $DRY -eq 1 ] && return 0
  curl -s -m 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT_ID" --data-urlencode text="nanoclaw disk: $*" >/dev/null || true
}

backup_recent() {  # refuse routine pruning if the last verified v2 backup is older than 36h
  [ -r "$BACKUP_STATUS" ] || { log "no backup status file — skipping"; return 1; }
  local ts; ts=$(cut -d' ' -f1 "$BACKUP_STATUS")
  [ $(( $(date +%s) - ts )) -lt 129600 ] || { log "last verified backup is >36h old — skipping"; return 1; }
}

docker_prune() {  # $1 = keep-storage for build cache
  run docker image prune -f
  run docker builder prune -f --keep-storage "$1"
  run docker container prune -f --filter until=48h
}

rotate_logs() {  # copy+truncate so the running service keeps its file handle
  for f in "$LOGDIR"/nanoclaw.log "$LOGDIR"/nanoclaw.error.log; do
    [ -f "$f" ] && [ "$(stat -c %s "$f")" -gt 20971520 ] || continue
    if [ $DRY -eq 1 ]; then log "DRY: rotate $f"; continue; fi
    gzip -c "$f" > "$f.$(date +%Y%m%d).gz" && : > "$f" && log "rotated $f"
    ls -t "$f".*.gz 2>/dev/null | tail -n +5 | xargs -r rm -f
  done
}

prune_claude_versions() {  # keep 3 newest + whichever one ~/.local/bin/claude points to
  local dir="$HOME/.local/share/claude/versions" cur
  cur=$(basename "$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null)")
  ls "$dir" 2>/dev/null | sort -V | head -n -3 | while read -r v; do
    [ "$v" = "$cur" ] && continue
    run rm -f "$dir/$v"
  done
}

case "$MODE" in
  status)
    log "/ used: $(used_pct)%  free: $(free_h)"
    docker system df 2>&1
    du -sh "$HOME/.npm/_cacache" "$HOME/.cache/uv" "$HOME/.local/share/pnpm" "$HOME/.local/share/claude/versions" 2>/dev/null
    [ -r "$BACKUP_STATUS" ] && log "last v2 backup: $(date -d @"$(cut -d' ' -f1 "$BACKUP_STATUS")") $(cut -d' ' -f2- "$BACKUP_STATUS")" || log "no v2 backup status"
    ;;
  daily)
    log "daily start: / at $(used_pct)% ($(free_h) free)"
    backup_recent && docker_prune "$KEEP_CACHE"
    log "daily done: / at $(used_pct)% ($(free_h) free)"
    ;;
  weekly)
    log "weekly start: / at $(used_pct)% ($(free_h) free)"
    if backup_recent; then
      run npm cache clean --force
      run pnpm store prune
      run uv cache prune
      prune_claude_versions
    fi
    rotate_logs
    log "weekly done: / at $(used_pct)% ($(free_h) free)"
    ;;
  watchdog)
    p=$(used_pct)
    [ "$p" -ge "$WARN_PCT" ] || exit 0
    log "watchdog: / at ${p}% — emergency prune"
    avail_before=$(df --output=avail -k / | tail -1 | tr -dc '0-9')
    run docker builder prune -af
    run docker image prune -f
    run docker container prune -f --filter until=48h
    run npm cache clean --force
    run uv cache prune
    avail_after=$(df --output=avail -k / | tail -1 | tr -dc '0-9')
    p2=$(used_pct)
    freed_mb=$(( (avail_after - avail_before) / 1024 ))
    if [ "$p2" -ge "$CRIT_PCT" ]; then
      alert "CRITICAL: / still at ${p2}% after auto-prune (${p}% before), $(free_h) free. Manual action needed (snaps, journal, old VMs)."
    elif [ "$freed_mb" -ge "$ALERT_MIN_FREED_MB" ]; then
      alert "/ was ${p}%, auto-pruned to ${p2}% (freed ${freed_mb}MB, $(free_h) free)."
    else
      log "watchdog: prune freed ${freed_mb}MB, / at ${p2}% — below alert threshold, no message"
    fi
    ;;
  *) echo "usage: $0 {status|daily|weekly|watchdog} [--dry-run]"; exit 2 ;;
esac
