/**
 * Minimal Google REST client for the in-repo Calendar / Drive MCP servers.
 *
 * Deliberately sends NO Authorization header: every request goes through the
 * OneCLI gateway (HTTPS_PROXY), which recognises the Google hostnames and
 * injects the real OAuth bearer from its vault. The container never holds a
 * usable token — same invariant as the Gmail MCP.
 */

const BASE = 'https://www.googleapis.com';
const TIMEOUT_MS = 30_000;

export class GoogleApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly reason?: string,
  ) {
    super(message);
    this.name = 'GoogleApiError';
  }
}

export type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

export interface RequestOptions {
  method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  query?: Record<string, string | number | boolean | undefined>;
  body?: unknown;
  fetchImpl?: FetchLike;
}

export function buildUrl(path: string, query?: RequestOptions['query']): string {
  const url = new URL(path.startsWith('http') ? path : BASE + path);
  for (const [k, v] of Object.entries(query ?? {})) {
    if (v !== undefined && v !== '') url.searchParams.set(k, String(v));
  }
  return url.toString();
}

/** Turn a non-2xx response body into an actionable message for the agent. */
export function describeError(status: number, bodyText: string): GoogleApiError {
  let message = bodyText.slice(0, 300);
  let reason: string | undefined;
  try {
    const parsed = JSON.parse(bodyText) as {
      error?: string | { message?: string; status?: string; errors?: { reason?: string }[]; details?: { reason?: string }[] };
      message?: string;
    };
    if (typeof parsed.error === 'string') {
      // OneCLI gateway envelope, e.g. {"error":"credential_not_found",...}
      reason = parsed.error;
      message = parsed.message ?? parsed.error;
    } else if (parsed.error) {
      message = parsed.error.message ?? message;
      reason = parsed.error.errors?.[0]?.reason ?? parsed.error.details?.[0]?.reason ?? parsed.error.status;
    }
  } catch {
    /* not JSON — keep the raw snippet */
  }

  let hint = '';
  // Reason-specific hints first: they are more precise than the status code.
  if (reason === 'credential_not_found') {
    hint = ' OneCLI has no credential for this host — check that the Google app is connected and assigned to this agent.';
  } else if (reason === 'SERVICE_DISABLED' || reason === 'accessNotConfigured') {
    hint = ' The API is disabled for the Google Cloud project that owns the OAuth client — it must be enabled in the Cloud Console.';
  } else if (status === 401) {
    hint = ' The Google connection in OneCLI looks expired or revoked — the owner needs to reconnect it in the OneCLI web UI.';
  } else if (status === 403) {
    hint = ' The connected account may lack access, or the OAuth scopes granted do not allow this operation.';
  } else if (status === 404) {
    hint = ' Not found — check the id (and that the connected account can see it).';
  }
  return new GoogleApiError(`Google API ${status}${reason ? ` (${reason})` : ''}: ${message}.${hint}`, status, reason);
}

async function doFetch(url: string, init: RequestInit, fetchImpl: FetchLike): Promise<Response> {
  const withTimeout = { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) };
  let res = await fetchImpl(url, withTimeout);
  if (res.status === 429 || res.status === 503) {
    await new Promise((r) => setTimeout(r, 1000));
    res = await fetchImpl(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
  }
  return res;
}

export async function googleJson<T = unknown>(path: string, opts: RequestOptions = {}): Promise<T> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const headers: Record<string, string> = { Accept: 'application/json' };
  const init: RequestInit = { method: opts.method ?? 'GET', headers };
  if (opts.body !== undefined) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.body);
  }
  const res = await doFetch(buildUrl(path, opts.query), init, fetchImpl);
  const text = await res.text();
  if (!res.ok) throw describeError(res.status, text);
  return (text ? JSON.parse(text) : {}) as T;
}

/**
 * Fetch a response body as text, refusing to buffer more than `maxBytes`.
 * Returns the decoded text and whether it was cut off.
 */
export async function googleText(
  path: string,
  opts: RequestOptions & { maxBytes: number },
): Promise<{ text: string; truncated: boolean }> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const res = await doFetch(buildUrl(path, opts.query), { method: 'GET' }, fetchImpl);
  if (!res.ok) throw describeError(res.status, await res.text());
  if (!res.body) return { text: '', truncated: false };

  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let truncated = false;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    chunks.push(value);
    if (total > opts.maxBytes) {
      truncated = true;
      await reader.cancel();
      break;
    }
  }
  const buf = new Uint8Array(Math.min(total, opts.maxBytes + 4));
  let off = 0;
  for (const c of chunks) {
    const slice = c.subarray(0, Math.max(0, buf.length - off));
    buf.set(slice, off);
    off += slice.byteLength;
  }
  return { text: new TextDecoder('utf-8').decode(buf), truncated };
}
