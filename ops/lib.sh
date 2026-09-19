# Shared config for the ops/ scripts (baz, backup-nanoclaw-v2.sh, nanoclaw-cleanup.sh).
# Sourced, not executed. Every value can be overridden in the environment or in
# ~/.config/nanoclaw/ops.env (see ops/ops.env.example).

OPS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[1]}")")" && pwd)"
NANOCLAW_HOME="${NANOCLAW_HOME:-$(dirname "$OPS_DIR")}"

OPS_ENV="${OPS_ENV:-$HOME/.config/nanoclaw/ops.env}"
# shellcheck disable=SC1090
[ -r "$OPS_ENV" ] && . "$OPS_ENV"

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
EXTERNAL_BACKUP_DIR="${EXTERNAL_BACKUP_DIR:-}"          # empty = no off-box copy
ALERT_ENV="${ALERT_ENV:-$HOME/.config/nanoclaw/alert.env}"  # TG_BOT_TOKEN / TG_CHAT_ID; optional
BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-$BACKUP_DIR/.last-backup-v2-ok}"

export DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}"
_node_bin="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="$OPS_DIR:$HOME/bin:$HOME/.local/bin:${_node_bin:+$_node_bin:}$PATH"
