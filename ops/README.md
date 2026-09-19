# ops/ — running NanoClaw on a host

`baz` is the single entry point (symlink it into your PATH: `ln -s $PWD/baz ~/bin/baz`).

| Command | Does |
|---|---|
| `baz start` / `baz down` | restart / stop NanoClaw (`start-nanoclaw.sh`, `nanoclaw.pid`) |
| `baz recover [--check\|--ensure]` | full recovery after a power cut or reboot (`recover-after-shutdown.sh`) |
| `baz backup [--dry-run]` | verified backup of `groups/`, all SQLite DBs (WAL-safe), Claude transcripts, `container/`, uncommitted patch |
| `baz cleanup [status\|daily\|weekly\|watchdog] [--dry-run]` | Docker/npm/pnpm/uv cache hygiene, log rotation, disk watchdog + Telegram alert |
| `baz status` / `baz health` / `baz logs [-e]` / `baz wiring` | state, Gmail/Calendar/Drive check, logs, MCP wiring preview |

## Safety rules
- Cleanup never touches `data/`, `groups/`, Docker volumes or bind mounts, and never runs `docker image prune -a` or `volume prune`.
- Routine cleanup refuses to run without a verified backup from the last 36h.
- Credentials are never backed up: `data/env`, `~/.gmail-mcp`, the OneCLI vault.

## Config
Scripts derive paths from their own location; override via env or `~/.config/nanoclaw/ops.env`
(see `ops.env.example`, `alert.env.example`, `crontab.example`).
