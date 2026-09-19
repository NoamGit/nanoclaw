/**
 * Tiny stdio MCP server bootstrap shared by the Google Calendar / Drive
 * servers. Uses the same official SDK (`@modelcontextprotocol/sdk`) as the
 * nanoclaw MCP server — no third-party MCP code.
 */
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

export interface GoogleTool {
  name: string;
  description: string;
  inputSchema: { type: 'object'; properties: Record<string, unknown>; required?: string[] };
  handler: (args: Record<string, unknown>) => Promise<unknown>;
}

export function toResult(value: unknown): { content: { type: 'text'; text: string }[] } {
  return { content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }] };
}

export async function callTool(tools: GoogleTool[], name: string, args: Record<string, unknown>) {
  const tool = tools.find((t) => t.name === name);
  if (!tool) return { ...toResult(`Unknown tool: ${name}`), isError: true };
  try {
    return toResult(await tool.handler(args));
  } catch (err) {
    return { ...toResult(err instanceof Error ? err.message : String(err)), isError: true };
  }
}

export async function serve(serverName: string, tools: GoogleTool[]): Promise<void> {
  const server = new Server({ name: serverName, version: '1.0.0' }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
  }));
  server.setRequestHandler(CallToolRequestSchema, async (req) =>
    callTool(tools, req.params.name, (req.params.arguments ?? {}) as Record<string, unknown>),
  );
  await server.connect(new StdioServerTransport());
  console.error(`[${serverName}] started with ${tools.length} tools`);
}
