/**
 * ops/apply-mcp-wiring.ts — idempotently apply ops/mcp-wiring.json to the
 * central DB (container_configs.mcp_servers / additional_mounts).
 *
 * Run by the crash-recovery / init flow so MCP wiring survives a restored or
 * rebuilt database. Only adds or updates the listed servers; never removes.
 * Groups are matched by folder, so ids may differ between installs.
 *
 *   pnpm exec tsx ops/apply-mcp-wiring.ts [--dry-run] [--db data/v2.db]
 *
 * Exit: 0 = applied/up to date (missing groups only warn), 1 = bad manifest/DB.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

import Database from 'better-sqlite3';

interface Mount {
  hostPath: string;
  containerPath: string;
  readonly: boolean;
}
interface Manifest {
  servers: Record<string, { config: Record<string, unknown>; requiresMounts?: Mount[] }>;
  groups: Record<string, string[]>;
}

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const dbArg = args.indexOf('--db');
const dbPath = dbArg >= 0 ? args[dbArg + 1] : 'data/v2.db';
const manifestPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'mcp-wiring.json');

/** Stable stringify (sorted keys) so equality ignores key order. */
function canon(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canon).join(',')}]`;
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canon(o[k])}`).join(',')}}`;
  }
  return JSON.stringify(v);
}

function fail(msg: string): never {
  console.error(`[mcp-wiring] ERROR: ${msg}`);
  process.exit(1);
}

let manifest: Manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as Manifest;
} catch (err) {
  fail(`cannot read ${manifestPath}: ${err instanceof Error ? err.message : String(err)}`);
}
for (const [folder, names] of Object.entries(manifest.groups)) {
  for (const n of names) if (!manifest.servers[n]) fail(`group "${folder}" references undefined server "${n}"`);
}
if (!fs.existsSync(dbPath)) fail(`database not found: ${dbPath}`);

const db = new Database(dbPath);
db.pragma('busy_timeout = 5000');
let changedGroups = 0;
let warnings = 0;

const getGroup = db.prepare('SELECT id FROM agent_groups WHERE folder = ?');
const getCfg = db.prepare('SELECT mcp_servers, additional_mounts FROM container_configs WHERE agent_group_id = ?');
const setCfg = db.prepare('UPDATE container_configs SET mcp_servers = ?, additional_mounts = ?, updated_at = ? WHERE agent_group_id = ?');

for (const [folder, names] of Object.entries(manifest.groups)) {
  const group = getGroup.get(folder) as { id: string } | undefined;
  if (!group) {
    console.warn(`[mcp-wiring] WARN: no agent group with folder "${folder}" — skipped`);
    warnings++;
    continue;
  }
  const row = getCfg.get(group.id) as { mcp_servers: string | null; additional_mounts: string | null } | undefined;
  if (!row) {
    console.warn(`[mcp-wiring] WARN: no container_configs row for "${folder}" (${group.id}) — skipped`);
    warnings++;
    continue;
  }

  const servers = JSON.parse(row.mcp_servers || '{}') as Record<string, unknown>;
  const mounts = JSON.parse(row.additional_mounts || '[]') as Mount[];
  const changes: string[] = [];

  for (const name of names) {
    const def = manifest.servers[name];
    if (canon(servers[name]) !== canon(def.config)) {
      changes.push(`${name in servers ? 'update' : 'add'} server ${name}`);
      servers[name] = def.config;
    }
    for (const m of def.requiresMounts ?? []) {
      // Match by containerPath; never override a mount someone customised.
      if (!mounts.some((x) => x.containerPath === m.containerPath)) {
        changes.push(`add mount ${m.containerPath}`);
        mounts.push(m);
      }
    }
  }

  if (changes.length === 0) {
    console.log(`[mcp-wiring] ${folder}: up to date`);
    continue;
  }
  changedGroups++;
  console.log(`[mcp-wiring] ${folder}: ${changes.join(', ')}${dryRun ? ' (dry run)' : ''}`);
  if (!dryRun) setCfg.run(JSON.stringify(servers), JSON.stringify(mounts), new Date().toISOString(), group.id);
}

db.close();
console.log(`[mcp-wiring] done: ${changedGroups} group(s) ${dryRun ? 'would change' : 'changed'}, ${warnings} warning(s)`);
