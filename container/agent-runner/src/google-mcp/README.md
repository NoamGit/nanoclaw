# In-repo Google Calendar + Drive MCP servers

Small stdio MCP servers that call Google's **classic REST APIs** through the
OneCLI gateway. They exist because Google's official remote MCP servers
(`calendarmcp.googleapis.com`, `drivemcp.googleapis.com`) are not yet mapped to
OneCLI's Google OAuth connections (`credential_not_found`), and we do not want
third-party MCP packages touching this data.

- Only dependency: the official `@modelcontextprotocol/sdk` (already used by agent-runner).
- **No token ever reaches the container.** Requests carry no `Authorization`
  header; OneCLI (via `HTTPS_PROXY`, inherited by MCP child processes) injects it.
- Source is mounted live at `/app/src`, so changes need **no image rebuild**.

| Server | Entry | Tools |
|--------|-------|-------|
| `calendar` | `google-mcp/calendar.ts` | `list_calendars`, `list_events`, `get_event`, `create_event`, `update_event`, `delete_event`, `get_freebusy` |
| `drive` (read-only) | `google-mcp/drive.ts` | `search_files`, `get_file`, `read_file` |

Safety defaults: event writes send **no invitation emails** unless `sendUpdates`
is set; Drive is read-only; tool descriptions mark event/file text as untrusted data.

## Prerequisites
1. Connect **Google Calendar** / **Google Drive** in the OneCLI web UI (Apps).
2. Enable the **Calendar API** / **Drive API** on the Google Cloud project that
   owns the OAuth client (the one named in any `SERVICE_DISABLED` error).
3. Each agent's OneCLI `secretMode` must be `all` (or have the app assigned).

## Wire into an agent group
Wiring is declared in `ops/mcp-wiring.json` (per group folder) and applied idempotently by
`ops/apply-mcp-wiring.ts` — `start-nanoclaw.sh` runs it on every start/recovery, so wiring survives a
restored DB. Edit the manifest, then run `pnpm exec tsx ops/apply-mcp-wiring.ts` (add `--dry-run` to preview).
Health check (real read-only call per service): `python3 ops/mcp-health.py`.

Manual equivalent for a single group:
```bash
GID=<agent-group-id>
pnpm exec tsx scripts/q.ts data/v2.db "update container_configs set mcp_servers=json_set(json_set(mcp_servers,'\$.calendar',json('{\"command\":\"bun\",\"args\":[\"/app/src/google-mcp/calendar.ts\"],\"env\":{}}')),'\$.drive',json('{\"command\":\"bun\",\"args\":[\"/app/src/google-mcp/drive.ts\"],\"env\":{}}')), updated_at=datetime('now') where agent_group_id='$GID'"
```
Takes effect on the group's next container spawn.

## Tests
```bash
docker run --rm -v "$PWD/container/agent-runner/src:/app/src:ro" -w /app \
  --entrypoint bun <agent-image> test src/google-mcp
```
