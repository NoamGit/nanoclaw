# Bank MCP Server — v2 Re-registration Guide

This documents the custom Israeli bank MCP integration so it can be re-registered after the v1→v2 migration.

## What it is

A Docker container (`bank-mcp-server`) that scrapes Israeli bank and credit card accounts daily and exposes them as an MCP HTTP server. The agent accesses it via the `mcp__israeli-bank__*` tools defined in `container/skills/israeli-finance/SKILL.md`.

**Connected accounts:**
- Bank Leumi — checking account
- Max (Leumi Card) — credit card
- Isracard — credit card (Noam's)
- Isracard 2 — credit card (Eden's)

Data refreshes daily at 06:00 via an automated cron job inside the container.

## Runtime details

| Property | Value |
|---|---|
| Container name | `bank-mcp-server` |
| Docker image | `financial-mcp-mcp-server` (local build) |
| MCP endpoint | `http://bank-mcp-server:3000` (HTTP MCP) |
| Networks | `onecli_onecli` (shared with nanoclaw containers), `bank-assistant-network` |
| Data volume | `financial-mcp_bank-data` → `/app/data` inside container |
| Env var | `POSTGRES_PORT=5433` in `.env` (used by the scraper's local PostgreSQL) |

The container is reachable by hostname (`bank-mcp-server`) from any container on the `onecli_onecli` network — which is how nanoclaw agent containers reach it. No ports are published to the host.

## How to re-register in v2

After running `migrate-v2.sh`, register the MCP server for each agent group that needs financial access (currently: `home` and `main`):

```bash
# Register for the home agent group
ncl groups config add-mcp-server \
  --group home \
  --name israeli-bank \
  --url http://bank-mcp-server:3000

# Register for the main agent group
ncl groups config add-mcp-server \
  --group main \
  --name israeli-bank \
  --url http://bank-mcp-server:3000
```

Also ensure `bank-mcp-server` is in the `NO_PROXY` env for the group containers (v2 sets this via the container config, not hardcoded in `container-runner.ts`):

```bash
ncl groups config update --group home --add-env NO_PROXY=localhost,127.0.0.1,onecli,bank-mcp-server
ncl groups config update --group main --add-env NO_PROXY=localhost,127.0.0.1,onecli,bank-mcp-server
```

The `israeli-finance` container skill (`container/skills/israeli-finance/`) is copied automatically by the migration script — no manual action needed for the skill itself.

## Verifying it works

Inside a container (via Baz), run:
```
mcp__israeli-bank__get_data_freshness
```

If it returns `fresh` or `stale`, the connection is working. If it errors, check that `bank-mcp-server` container is running (`docker ps | grep bank-mcp`) and on the `onecli_onecli` network.
