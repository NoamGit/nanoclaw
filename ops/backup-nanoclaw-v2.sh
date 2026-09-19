#!/bin/bash
# Backup of nanoclaw-v2 state: memory, conversation history, session DBs.
#   --dry-run   build + verify the archive in a temp dir, do not keep it or touch retention
# Never included: data/env, ~/.gmail-mcp, OneCLI vault (credentials).
set -uo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"
SRC="$NANOCLAW_HOME"
LOCAL_DIR="$BACKUP_DIR"
EXTERNAL_DIR="$EXTERNAL_BACKUP_DIR"
STATUS_FILE="$BACKUP_STATUS_FILE"
KEEP_LOCAL_DAYS=30
KEEP_EXTERNAL_DAYS=90
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

TS=$(date +%Y%m%d_%H%M%S)
NAME="nanoclaw-v2_${TS}.tar.gz"
mkdir -p "$LOCAL_DIR"
STAGE=$(mktemp -d "$LOCAL_DIR/.stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
log() { echo "[$(date)] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# 1. Consistent snapshots of every SQLite DB (WAL-safe, integrity-checked)
python3 - "$SRC" "$STAGE/snap" <<'PY' || fail "sqlite snapshot failed"
import sqlite3, sys, os, glob
src, dst = sys.argv[1], sys.argv[2]
dbs = [os.path.join(src, "data", "v2.db")] + glob.glob(os.path.join(src, "data", "v2-sessions", "**", "*.db"), recursive=True)
ok = bad = 0
for p in dbs:
    rel = os.path.relpath(p, src)
    out = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    try:
        s = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=30)
        d = sqlite3.connect(out)
        s.backup(d)
        r = d.execute("PRAGMA integrity_check").fetchone()[0]
        s.close(); d.close()
        if r != "ok": raise RuntimeError(f"integrity_check: {r}")
        ok += 1
    except Exception as e:
        bad += 1
        print(f"WARN: {rel}: {e}", file=sys.stderr)
print(f"sqlite snapshots: {ok} ok, {bad} failed")
sys.exit(1 if bad else 0)
PY

# 2. Archive files (DBs excluded here; the snapshots are appended below)
TAR="$STAGE/${NAME%.gz}"
tar cf "$TAR" -C "$SRC" \
  --ignore-failed-read \
  --exclude='node_modules' --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.sock' \
  --exclude='.claude-shared/skills' --exclude='.claude-shared/session-env' \
  --exclude='.claude-shared/sessions' --exclude='.claude-shared/backups' \
  --exclude='.claude-shared/policy-limits.json' \
  groups data container ops start-nanoclaw.sh 2>"$STAGE/tar.err"
rc=$?
[ $rc -le 2 ] || fail "tar failed (rc=$rc): $(head -3 "$STAGE/tar.err")"
tar rf "$TAR" -C "$STAGE/snap" data || fail "appending DB snapshots failed"
# drop credentials that live inside data/
tar --delete -f "$TAR" data/env 2>/dev/null || true
# uncommitted code changes as a patch
git -C "$SRC" diff > "$STAGE/uncommitted.patch" 2>/dev/null && tar rf "$TAR" -C "$STAGE" uncommitted.patch
gzip -f "$TAR"
OUT="$STAGE/$NAME"

# 3. Verify before trusting it
gzip -t "$OUT" || fail "gzip integrity check failed"
LIST=$(tar tzf "$OUT")
echo "$LIST" | grep -qx 'data/v2.db' || fail "archive is missing data/v2.db"
DBS=$(echo "$LIST" | grep -c '\.db$')
[ "$DBS" -ge 30 ] || fail "archive has only $DBS DBs (expected >=30)"
echo "$LIST" | grep -q '^groups/home/' || fail "archive is missing groups/home"
SIZE=$(stat -c %s "$OUT")
log "verified: $NAME, $SIZE bytes, $DBS databases, $(echo "$LIST" | wc -l) entries (tar rc=$rc)"
[ -s "$STAGE/tar.err" ] && log "tar warnings (unreadable container-owned files, expected): $(wc -l < "$STAGE/tar.err") lines"

if [ $DRY -eq 1 ]; then log "dry-run: not keeping archive"; exit 0; fi

# 4. Keep, copy off-box, prune old ones
mv "$OUT" "$LOCAL_DIR/$NAME"
if [ -z "$EXTERNAL_DIR" ]; then
  log "no EXTERNAL_BACKUP_DIR configured, skipping off-box copy"
elif [ -d "$EXTERNAL_DIR" ]; then
  cp "$LOCAL_DIR/$NAME" "$EXTERNAL_DIR/" && log "external copy written: $EXTERNAL_DIR/$NAME"
  find "$EXTERNAL_DIR" -name 'nanoclaw-v2_*.tar.gz' -mtime +$KEEP_EXTERNAL_DAYS -delete
else
  log "WARNING: external drive not mounted, skipping external copy"
fi
find "$LOCAL_DIR" -name 'nanoclaw-v2_*.tar.gz' -mtime +$KEEP_LOCAL_DAYS -delete
echo "$(date +%s) $LOCAL_DIR/$NAME $SIZE" > "$STATUS_FILE"
log "backup v2 complete: $LOCAL_DIR/$NAME"
