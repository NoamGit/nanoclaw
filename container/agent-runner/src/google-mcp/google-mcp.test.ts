import { describe, expect, test } from 'bun:test';

import { buildUrl, describeError, googleText } from './google-api.js';
import { calendarTools, toEventTime } from './calendar-tools.js';
import { buildDriveQuery, driveTools, escapeQ, pickReadMode } from './drive-tools.js';
import { callTool } from './serve.js';

type Call = { url: string; init?: RequestInit };
function fakeFetch(responder: (call: Call) => Response) {
  const calls: Call[] = [];
  const fn = async (url: string, init?: RequestInit) => {
    const call = { url, init };
    calls.push(call);
    return responder(call);
  };
  return { fn, calls };
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const tool = (tools: ReturnType<typeof calendarTools>, name: string) => tools.find((t) => t.name === name)!;

describe('google-api', () => {
  test('buildUrl drops undefined/empty query values', () => {
    expect(buildUrl('/x', { a: 1, b: undefined, c: '', d: false })).toBe('https://www.googleapis.com/x?a=1&d=false');
  });

  test('describeError adds actionable hints', () => {
    expect(describeError(401, '{"error":{"message":"Invalid Credentials"}}').message).toContain('reconnect');
    const disabled = describeError(403, JSON.stringify({ error: { message: 'API disabled', errors: [{ reason: 'accessNotConfigured' }] } }));
    expect(disabled.message).toContain('Cloud Console');
    const gateway = describeError(401, '{"error":"credential_not_found","message":"No credentials configured"}');
    expect(gateway.reason).toBe('credential_not_found');
    expect(gateway.message).toContain('OneCLI has no credential');
  });

  test('describeError explains a proxy auth failure (407) and empty bodies', () => {
    const e = describeError(407, '');
    expect(e.message).toContain('proxy rejected');
    expect(e.message).not.toContain(': .');
  });

  test('googleText stops reading past maxBytes', async () => {
    const big = 'a'.repeat(5000);
    const { fn } = fakeFetch(() => new Response(big));
    const r = await googleText('/x', { fetchImpl: fn, maxBytes: 100 });
    expect(r.truncated).toBe(true);
    expect(r.text.length).toBeLessThan(200);
  });
});

describe('calendar', () => {
  test('toEventTime accepts dates and RFC3339, rejects junk', () => {
    expect(toEventTime('2026-09-21')).toEqual({ date: '2026-09-21' });
    expect(toEventTime('2026-09-21T14:00:00+03:00')).toEqual({ dateTime: '2026-09-21T14:00:00+03:00' });
    expect(toEventTime('2026-09-21T14:00:00', 'Asia/Jerusalem')).toEqual({ dateTime: '2026-09-21T14:00:00', timeZone: 'Asia/Jerusalem' });
    expect(() => toEventTime('tomorrow at 3')).toThrow('Invalid time');
  });

  test('create_event: no auth header, no invites by default, correct body', async () => {
    const { fn, calls } = fakeFetch(() => json({ id: 'e1', summary: 'Dentist', start: { dateTime: '2026-09-21T14:00:00+03:00' }, end: {} }));
    const out = (await tool(calendarTools(fn), 'create_event').handler({
      summary: 'Dentist',
      start: '2026-09-21T14:00:00+03:00',
      end: '2026-09-21T15:00:00+03:00',
      attendees: ['a@b.com'],
    })) as { id: string };
    expect(out.id).toBe('e1');
    const c = calls[0];
    expect(c.url).toContain('/calendar/v3/calendars/primary/events');
    expect(c.url).toContain('sendUpdates=none');
    expect((c.init?.headers as Record<string, string>).Authorization).toBeUndefined();
    expect(JSON.parse(c.init?.body as string).attendees).toEqual([{ email: 'a@b.com' }]);
  });

  test('ids are path-encoded so they cannot alter the URL', async () => {
    const { fn, calls } = fakeFetch(() => json({}));
    await tool(calendarTools(fn), 'get_event').handler({ calendarId: 'x/../y', eventId: 'a?b' });
    expect(calls[0].url).toContain('/calendars/x%2F..%2Fy/events/a%3Fb');
  });

  test('update_event refuses an empty patch; delete uses DELETE', async () => {
    const { fn, calls } = fakeFetch(() => new Response(null, { status: 204 }));
    const t = calendarTools(fn);
    await expect(tool(t, 'update_event').handler({ eventId: 'e1' })).rejects.toThrow('Nothing to update');
    await tool(t, 'delete_event').handler({ eventId: 'e1' });
    expect(calls[0].init?.method).toBe('DELETE');
  });

  test('list_events requires an offset on timeMin/timeMax', async () => {
    const { fn } = fakeFetch(() => json({ items: [] }));
    await expect(tool(calendarTools(fn), 'list_events').handler({ timeMin: '2026-09-21T00:00:00' })).rejects.toThrow('offset');
  });
});

describe('drive', () => {
  test('escapeQ / buildDriveQuery neutralise quote injection', () => {
    expect(escapeQ("it's \\ fine")).toBe("it\\'s \\\\ fine");
    const q = buildDriveQuery({ text: "x' or name contains 'secret" });
    expect(q).toBe("trashed = false and fullText contains 'x\\' or name contains \\'secret'");
  });

  test('pickReadMode', () => {
    expect(pickReadMode('application/vnd.google-apps.document')).toEqual({ kind: 'export', exportMime: 'text/plain' });
    expect(pickReadMode('application/vnd.google-apps.spreadsheet')).toMatchObject({ exportMime: 'text/csv' });
    expect(pickReadMode('text/markdown')).toEqual({ kind: 'download' });
    expect(pickReadMode('application/pdf').kind).toBe('unsupported');
    expect(pickReadMode('application/vnd.google-apps.folder').kind).toBe('unsupported');
  });

  test('read_file exports a Google Doc as text and truncates', async () => {
    const { fn, calls } = fakeFetch((c) =>
      c.url.includes('/export')
        ? new Response('x'.repeat(5000))
        : json({ id: 'd1', name: 'Plan', mimeType: 'application/vnd.google-apps.document' }),
    );
    const out = (await driveTools(fn).find((t) => t.name === 'read_file')!.handler({ fileId: 'd1', max_chars: 1000 })) as {
      truncated: boolean;
      content: string;
    };
    expect(out.truncated).toBe(true);
    expect(out.content.length).toBe(1000);
    expect(calls[1].url).toContain('/files/d1/export?mimeType=text%2Fplain');
  });

  test('read_file refuses binary files without downloading them', async () => {
    const { fn, calls } = fakeFetch(() => json({ id: 'p1', name: 'x.pdf', mimeType: 'application/pdf', size: '100' }));
    const out = (await driveTools(fn).find((t) => t.name === 'read_file')!.handler({ fileId: 'p1' })) as { error: string };
    expect(out.error).toContain('Binary file');
    expect(calls.length).toBe(1);
  });
});

describe('serve.callTool', () => {
  test('unknown tool and handler errors are isError results, not throws', async () => {
    const tools = [{ name: 't', description: '', inputSchema: { type: 'object' as const, properties: {} }, handler: async () => { throw new Error('boom'); } }];
    expect((await callTool(tools, 'nope', {})).isError).toBe(true);
    const r = await callTool(tools, 't', {});
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toBe('boom');
  });
});
