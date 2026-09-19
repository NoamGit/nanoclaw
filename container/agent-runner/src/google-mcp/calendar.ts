#!/usr/bin/env bun
/** Google Calendar MCP server (stdio). Entry: `bun /app/src/google-mcp/calendar.ts` */
import { calendarTools } from './calendar-tools.js';
import { serve } from './serve.js';

await serve('google-calendar', calendarTools());
