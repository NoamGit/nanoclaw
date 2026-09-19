/**
 * Tests for the core MCP tools' interaction with the per-batch routing
 * context. The agent-runner sets a current `inReplyTo` at the top of each
 * batch in poll-loop, and outbound writes from MCP tools (send_message,
 * send_file) must pick it up so a2a return-path routing on the host can
 * correlate replies back to the originating session.
 */
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { initTestSessionDb, closeSessionDb, getInboundDb } from '../db/connection.js';
import { getUndeliveredMessages } from '../db/messages-out.js';
import { setCurrentInReplyTo, clearCurrentInReplyTo } from '../current-batch.js';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { sendFile, sendMessage } from './core.js';

beforeEach(() => {
  initTestSessionDb();
  // Seed a peer agent destination
  getInboundDb()
    .prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
       VALUES ('peer', 'Peer', 'agent', NULL, NULL, 'ag-peer')`,
    )
    .run();
});

afterEach(() => {
  clearCurrentInReplyTo();
  closeSessionDb();
});

describe('send_message MCP tool — in_reply_to plumbing', () => {
  it('stamps current batch in_reply_to on outbound rows', async () => {
    setCurrentInReplyTo('inbound-msg-1');

    await sendMessage.handler({ to: 'peer', text: 'hello' });

    const out = getUndeliveredMessages();
    expect(out).toHaveLength(1);
    expect(out[0].in_reply_to).toBe('inbound-msg-1');
  });

  it('writes null when no batch is active', async () => {
    // No setCurrentInReplyTo before this call — simulates ad-hoc / out-of-batch invocation.
    await sendMessage.handler({ to: 'peer', text: 'hello' });

    const out = getUndeliveredMessages();
    expect(out).toHaveLength(1);
    expect(out[0].in_reply_to).toBeNull();
  });
});

describe('send_file MCP tool — outbox permissions (rootless Docker)', () => {
  it('leaves the message dir and file writable by the host so post-delivery cleanup can delete them', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'outbox-test-'));
    const src = path.join(root, 'photo.jpg');
    fs.writeFileSync(src, 'data');
    const prevUmask = process.umask(0o022); // the container's default: would make the dir 755
    const prevEnv = process.env.NANOCLAW_OUTBOX_DIR;
    process.env.NANOCLAW_OUTBOX_DIR = path.join(root, 'outbox');
    fs.mkdirSync(process.env.NANOCLAW_OUTBOX_DIR);
    try {
      // OUTBOX_ROOT is read at import time, so re-import a fresh copy of the module.
      const fresh = (await import(`./core.js?outbox=${Date.now()}`)) as { sendFile: typeof sendFile };
      const res = await fresh.sendFile.handler({ to: 'peer', path: src, text: 'hi' });
      expect(JSON.stringify(res)).toContain('File sent');

      const [msgDir] = fs.readdirSync(process.env.NANOCLAW_OUTBOX_DIR);
      const dirMode = fs.statSync(path.join(process.env.NANOCLAW_OUTBOX_DIR, msgDir)).mode & 0o777;
      const fileMode = fs.statSync(path.join(process.env.NANOCLAW_OUTBOX_DIR, msgDir, 'photo.jpg')).mode & 0o777;
      expect(dirMode).toBe(0o777);
      expect(fileMode).toBe(0o666);
    } finally {
      process.umask(prevUmask);
      if (prevEnv === undefined) delete process.env.NANOCLAW_OUTBOX_DIR;
      else process.env.NANOCLAW_OUTBOX_DIR = prevEnv;
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});
