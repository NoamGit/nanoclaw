#!/usr/bin/env bun
/** Google Drive MCP server (stdio, read-only). Entry: `bun /app/src/google-mcp/drive.ts` */
import { driveTools } from './drive-tools.js';
import { serve } from './serve.js';

await serve('google-drive', driveTools());
