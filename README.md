# PostBot

AI-driven social media scheduling. Claude drafts, schedules, and manages posts via MCP.
A worker fires them at the right time. Creatomate handles video processing.

## Quick start

```bash
# Install dependencies
pnpm install

# Copy env vars and fill in values
cp .env.example .env

# Run the MCP server (for Claude Desktop)
pnpm --filter mcp-server dev

# Run the worker
pnpm --filter worker dev

# Run the dashboard
pnpm --filter dashboard dev
```

## Adding to Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "postbot": {
      "command": "node",
      "args": ["/path/to/postbot/apps/mcp-server/dist/index.js"],
      "env": {
        "SUPABASE_URL": "https://zdjughkxryhabduhsdgg.supabase.co",
        "SUPABASE_SERVICE_ROLE_KEY": "your-service-role-key"
      }
    }
  }
}
```

## Channels

| Channel | Slug | Platforms |
|---------|------|-----------|
| OIO Racing | `oio` | Instagram, TikTok, YouTube |
| Tiny Prints | `tiny-prints` | Instagram, TikTok |
| Personal | `personal` | Instagram, Threads |

## Architecture

See `AGENTS.md` for the full spec including DB schema, MCP tool definitions,
worker behavior, and coding conventions.

## Supabase project

Project ID: `zdjughkxryhabduhsdgg`
URL: `https://zdjughkxryhabduhsdgg.supabase.co`
