# PostBot - Agent Specification

This document is the authoritative reference for all AI coding agents working on this repo.
Read it fully before writing any code. Do not deviate from the conventions here without
updating this file first.

---

## What PostBot is

An AI-driven social media scheduling system. Ian drops raw video/image and rough caption text
into a per-channel Claude chat. Claude rewrites the content for the audience, selects hashtags,
queries the schedule via MCP, and queues the post. A lightweight worker on a VPS polls the queue
and fires platform API calls at the scheduled time. Creatomate handles all video rendering.

**Claude is the UI.** There is no traditional admin dashboard for creating or editing posts.
Claude generates interactive artifacts for queue viewing, post editing, and performance stats.
The only standalone web UI is a read-only queue dashboard for glancing at on a phone.

---

## Monorepo structure

```
postbot/
  apps/
    mcp-server/       # MCP server Claude connects to (TypeScript, Node)
    worker/           # Publisher worker - polls queue, fires platform APIs (TypeScript, Node)
    dashboard/        # Read-only web queue viewer (Next.js, deployed to Vercel)
  packages/
    db/               # Supabase client, generated types, shared DB utilities
    types/            # Shared TypeScript types across apps
  supabase/
    migrations/       # SQL migration files - never edit applied migrations
  AGENTS.md           # This file
  .env.example        # All required env vars with descriptions
```

Use `pnpm` workspaces. Each app has its own `package.json`. Shared packages are in `packages/`.

---

## Supabase project

- **Project name:** postbot
- **Project ID:** `zdjughkxryhabduhsdgg`
- **API URL:** `https://zdjughkxryhabduhsdgg.supabase.co`
- **Region:** us-east-1

The schema is already migrated and seeded. Do not recreate tables or re-run seed data.
All future schema changes go in a new numbered migration file in `supabase/migrations/`.

### Connection

Always use the Supabase JS client (`@supabase/supabase-js`).
Always use the **service role key** on the server (worker, MCP server).
Never use the service role key in browser/client code.
Never hardcode credentials -- always read from environment variables.

```ts
import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { persistSession: false } }
)
```

---

## Database schema (live, confirmed)

All tables are in the `public` schema with RLS enabled.
The service role bypasses RLS. Never disable RLS.

### `channels`
| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| id | uuid | NO | PK, uuid_generate_v4() |
| name | text | NO | Display name |
| slug | text | NO | UNIQUE. 'oio', 'tiny-prints', 'personal' |
| voice_config | text | NO | Full Claude system prompt for this channel |
| audience_notes | text | YES | Who the audience is |
| hashtag_notes | text | YES | Claude guidance for tag selection |
| default_platforms | text[] | NO | Default: '{}' |
| active | boolean | NO | Default: true |
| created_at | timestamptz | NO | Default: now() |

### `accounts`
| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| id | uuid | NO | PK |
| channel_id | uuid | NO | FK -> channels.id CASCADE |
| platform | text | NO | 'instagram','youtube','threads','x' |
| handle | text | NO | e.g. '@OIORacing' |
| credentials_ref | text | NO | Env var name on worker e.g. 'OIO_INSTAGRAM_TOKEN' |
| active | boolean | NO | Default: true |
| created_at | timestamptz | NO | |
| UNIQUE | | | (channel_id, platform) |

### `queue_rules`
| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| id | uuid | NO | PK |
| channel_id | uuid | NO | FK -> channels.id CASCADE |
| platform | text | NO | |
| min_gap_hours | int | NO | Default: 12 |
| max_per_day | int | NO | Default: 2 |
| preferred_days | text[] | YES | e.g. ['tuesday','thursday','saturday'] |
| preferred_windows | jsonb | YES | [{"start":"17:00","end":"20:00"}] |
| created_at | timestamptz | NO | |
| UNIQUE | | | (channel_id, platform) |

### `hashtags`
| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| id | uuid | NO | PK |
| channel_id | uuid | NO | FK -> channels.id CASCADE |
| tag | text | NO | Include the # e.g. '#scca' |
| category | text | YES | 'racing', 'maker', 'general' etc |
| total_uses | int | NO | Default: 0 |
| avg_reach | numeric(10,2) | YES | Updated by metrics ingestion |
| avg_engagement | numeric(5,4) | YES | Ratio 0.0000-1.0000 |
| last_used | timestamptz | YES | |
| active | boolean | NO | Default: true |
| created_at | timestamptz | NO | |
| UNIQUE | | | (channel_id, tag) |

### `posts`
| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| id | uuid | NO | PK |
| channel_id | uuid | NO | FK -> channels.id CASCADE |
| raw_text | text | YES | Ian's original rough text |
| optimized_text | text | YES | Claude's rewrite |
| alt_text | text | YES | Accessibility / SEO |
| media | jsonb | NO | Default: '[]' -- see Media Object Schema below |
| target_platforms | text[] | NO | Default: '{}' |
| platform_overrides | jsonb | YES | Per-platform caption tweaks |
| mood | text | YES | 'hype','informational','community','product' |
| campaign_tag | text | YES | e.g. 'bmw2002-reveal' |
| embargoed_until | timestamptz | YES | Do not post before this time |
| scheduled_at | timestamptz | YES | Claude-proposed, Ian-approved |
| hashtags_used | text[] | YES | Default: '{}' |
| status | text | NO | See Status Lifecycle below |
| posted_at | timestamptz | YES | |
| platform_post_ids | jsonb | YES | {instagram:'xxx', youtube:'yyy'} |
| post_errors | jsonb | YES | {platform:'error message'} |
| is_evergreen | boolean | NO | Default: false |
| storage_cleared_at | timestamptz | YES | Null until cleanup runs |
| created_at | timestamptz | NO | |
| updated_at | timestamptz | NO | Auto-updated by trigger |

**Post status lifecycle:**
```
draft -> pending_approval -> approved -> posting -> posted
                                                 -> failed
                          -> cancelled
```
Worker only processes rows where `status = 'approved' AND scheduled_at <= now()`.

### `creatomate_jobs`
| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| id | uuid | NO | PK |
| post_id | uuid | NO | FK -> posts.id CASCADE |
| job_id | text | NO | UNIQUE. Creatomate's render ID |
| template_id | text | YES | Creatomate template if used |
| platform | text | NO | Which variant this job produces |
| input_url | text | NO | Source file URL sent to Creatomate |
| output_url | text | YES | Filled in when webhook fires |
| operations | jsonb | NO | What was requested: trim, overlay etc |
| status | text | NO | 'queued','rendering','done','failed' |
| error | text | YES | |
| started_at | timestamptz | YES | |
| completed_at | timestamptz | YES | |
| created_at | timestamptz | NO | |

### `post_metrics`
| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| id | uuid | NO | PK |
| post_id | uuid | NO | FK -> posts.id CASCADE |
| platform | text | NO | |
| reach | int | YES | |
| impressions | int | YES | |
| likes | int | YES | |
| comments | int | YES | |
| shares | int | YES | |
| saves | int | YES | |
| plays | int | YES | Video only |
| watch_time_avg | numeric(8,2) | YES | Seconds, video only |
| fetched_at | timestamptz | NO | Default: now() |
| UNIQUE | | | (post_id, platform, fetched_at) |

---

## Media object schema (posts.media JSONB array)

Each element in the `media` array follows this shape:

```ts
interface MediaObject {
  type: 'video' | 'image'
  raw_path: string              // Supabase/R2 path to original file
  processed_path?: string       // After Creatomate or Sharp processing
  thumbnail_path?: string       // JPEG thumbnail, always generated
  duration_seconds?: number     // Video only
  creatomate_job_id?: string    // Set when Creatomate job is submitted
  creatomate_status?: 'queued' | 'rendering' | 'done' | 'failed'
  platform_variants?: {         // Per-platform processed output paths
    instagram?: string
    youtube?: string
    threads?: string
    x?: string
  }
  storage_cleared_at?: string | null
}
```

---

## Seeded channel IDs (live in DB, do not re-insert)

| Slug | ID | Platforms |
|------|----|-----------|
| oio | 93b1db85-d063-49bb-b25c-87c27f32930b | instagram, youtube |
| personal | d88229d2-dc3b-4816-b4d0-8ac22d871342 | instagram, threads |
| tiny-prints | ca060f63-8256-474c-94c5-f7328111dde2 | instagram |

---

## MCP server (`apps/mcp-server`)

The MCP server is what Claude connects to. It exposes tools Claude calls during post creation,
queue management, and scheduling. It runs as a stdio MCP server using the
`@modelcontextprotocol/sdk` package.

**Runtime:** Node 20+, TypeScript, ESM modules
**Entry point:** `src/index.ts`
**Transport:** stdio (for Claude Desktop / Copilot MCP config)

### Required tools -- implement all of these

#### `get_channel_queue`
Returns the current post queue for a channel.
- Inputs: `channel_slug` (enum: oio|tiny-prints|personal), `limit` (int, default 20), `status` (string, default 'all')
- Returns: channel info, array of posts with all fields
- 'all' status returns draft + pending_approval + approved + posting only (not posted/cancelled)

#### `get_next_available_slot`
Returns the recommended next posting time for a channel/platform.
- Inputs: `channel_slug`, `platform`, `urgency` (enum: normal|soon|flexible, default normal)
- Logic: reads queue_rules for min_gap_hours and preferred_windows, checks last scheduled post, finds first open slot that respects max_per_day
- Returns: `suggested_time` (ISO), `suggested_time_human` (readable, Central Time), rules summary, last post time, number already queued
- 'soon' looks 2 days ahead, 'normal' 7 days, 'flexible' 14 days

#### `create_post`
Writes a new post to the queue with status 'pending_approval'.
- Inputs: `channel_slug`, `optimized_text`, `raw_text?`, `target_platforms[]`, `scheduled_at` (ISO datetime), `hashtags_used[]?`, `media[]?`, `mood?`, `campaign_tag?`, `alt_text?`, `is_evergreen?`
- Does NOT post to any platform -- only writes to DB
- Returns: created post id and full post object

#### `update_post`
Edits a queued post. Only works on draft/pending_approval/approved posts.
- Inputs: `post_id`, plus any subset of: `optimized_text`, `scheduled_at`, `hashtags_used`, `target_platforms`, `mood`, `campaign_tag`, `alt_text`, `is_evergreen`, `platform_overrides`
- Returns: updated post object

#### `approve_post`
Flips status from pending_approval to approved. Worker will then pick it up.
- Inputs: `post_id`
- Validates current status is pending_approval
- Returns: updated post

#### `cancel_post`
Sets status to cancelled. Soft delete only -- never hard delete.
- Inputs: `post_id`, `reason?`
- Works on any non-posted status
- Returns: confirmation

#### `get_hashtag_stats`
Returns the hashtag bank for a channel with performance data so Claude can make smart selections.
- Inputs: `channel_slug`, `category?` (filter by category)
- Returns: hashtags sorted by avg_engagement desc, includes total_uses and last_used

#### `get_channel_performance`
Aggregated engagement metrics for a channel over a time window.
- Inputs: `channel_slug`, `days` (int, default 28)
- Returns: per-platform aggregates (total reach, avg engagement, top performing post ids), best performing time slots, top hashtags by avg_engagement

#### `submit_creatomate_job`
Submits a video render job to Creatomate and records it in creatomate_jobs.
- Inputs: `post_id`, `platform`, `input_url`, `operations` (jsonb -- trim points, watermark, text overlays, output dimensions)
- Calls Creatomate API, stores job_id, sets creatomate_status on the relevant media object
- Returns: job_id, estimated completion

#### `get_creatomate_job_status`
Polls a Creatomate job for status.
- Inputs: `job_id`
- Returns: status, output_url if done, error if failed

#### `cleanup_post_storage`
Runs the storage cleanup flow for a posted post.
- Inputs: `post_id`
- Logic: checks all target platforms have confirmed post IDs, then either moves to /assets bucket (if is_evergreen) or deletes from storage, then sets storage_cleared_at
- Returns: what was deleted/moved

---

## Worker (`apps/worker`)

Node.js process that runs continuously on a VPS (Hetzner or Mac mini).
Polls Supabase every 60 seconds for approved posts due to fire.

**Key responsibilities:**
1. Poll `posts` where `status = 'approved' AND scheduled_at <= now() AND embargoed_until IS NULL OR embargoed_until <= now()`
2. Set status to 'posting' immediately (prevents double-fire)
3. For each target platform, stream the processed media variant from storage to the platform upload API
4. On success: write platform post ID to `platform_post_ids`, set `posted_at`, set status 'posted'
5. On failure: write error to `post_errors`, set status 'failed' (do not retry automatically -- alert and wait for manual review)
6. After all platforms confirm: call cleanup logic (check is_evergreen, delete or move raw files)
7. Separately: fetch engagement metrics 24h after `posted_at` and write to `post_metrics`

**Platform adapters** -- implement one module per platform:
- `src/platforms/instagram.ts`
- `src/platforms/youtube.ts`
- `src/platforms/threads.ts`
- `src/platforms/x.ts`

Each adapter exports: `upload(post: Post, mediaVariantUrl: string, caption: string): Promise<{ post_id: string }>`

Credentials are read from env vars. The account's `credentials_ref` column contains the env var name.
Example: `credentials_ref = 'OIO_INSTAGRAM_TOKEN'` means read `process.env.OIO_INSTAGRAM_TOKEN`.

**Creatomate webhook endpoint:**
The worker also runs an Express HTTP server on port 3001 to receive Creatomate webhooks.
On `POST /webhooks/creatomate`:
- Validate the request (check Creatomate signature header)
- Find the `creatomate_jobs` row by `job_id`
- Update `output_url`, `status`, `completed_at`
- Update the matching media object in `posts.media` (set `processed_path` and `creatomate_status`)
- If all platform variants for the post are done, set post status back to pending_approval (ready for Claude/Ian to approve)

---

## Dashboard (`apps/dashboard`)

Next.js app deployed to Vercel. Read-only. No post creation or editing here.

**Single page -- the queue view:**
- Week calendar grid showing scheduled posts per channel, color-coded by platform
- Status badges (draft, pending, approved, posted, failed)
- Click a post to expand and see caption + media thumbnail
- Realtime updates via Supabase Realtime subscription on the `posts` table
- No auth required (deploy behind Vercel password protection or just keep the URL private)

Use the Supabase `anon` key in the dashboard (not service role). Add a read-only RLS policy
for the dashboard's use case rather than exposing service role to the browser.

---

## Storage buckets

Four buckets in Supabase Storage (create manually in dashboard if not yet created):

| Bucket | Public | Max file size | Accepted types |
|--------|--------|---------------|----------------|
| media-raw | No | 5GB | video/mp4, video/quicktime, image/jpeg, image/png, image/heic, image/webp |
| media-processed | Yes | 1GB | video/mp4, image/jpeg, image/png, image/webp |
| media-assets | Yes | 1GB | video/mp4, image/jpeg, image/png, image/webp |
| media-thumbs | Yes | 10MB | image/jpeg, image/png, image/webp |

Storage path conventions:
- Raw: `{channel_slug}/{post_id}/raw.{ext}`
- Processed: `{channel_slug}/{post_id}/{platform}.mp4`
- Thumbs: `{channel_slug}/{post_id}/thumb.jpg`
- Assets (evergreen): `{channel_slug}/assets/{original_filename}`

---

## External services

### Creatomate
- API docs: https://creatomate.com/docs/api
- Base URL: `https://api.creatomate.com/v1`
- Auth: `Authorization: Bearer {CREATOMATE_API_KEY}`
- Key endpoint: `POST /renders` -- submit a render job
- Webhook: configure in Creatomate dashboard to point to `{WORKER_URL}/webhooks/creatomate`

Video operations object shape passed to `submit_creatomate_job`:
```json
{
  "trim_start": 0,
  "trim_end": 45,
  "watermark_text": "@OIORacing",
  "watermark_position": "bottom-right",
  "output_width": 1080,
  "output_height": 1920,
  "output_format": "mp4"
}
```
The worker translates this into Creatomate's render JSON format.

### Platform video upload notes
- **Instagram Reels:** Use Content Publishing API. Upload video via resumable upload, then publish.
- **YouTube Shorts:** Use YouTube Data API v3. Resumable upload to `/upload/youtube/v3/videos`.
- **Threads:** Use Threads API (Meta). Similar flow to Instagram.
- **X:** Use v2 media upload API. Chunked upload required for video.

All platform tokens go in env vars referenced by `accounts.credentials_ref`.

---

## Environment variables

See `.env.example` for the full list. Never commit real values. All apps share the same
env var names -- use a single `.env` at the repo root for local dev.

---

## Coding conventions

- TypeScript strict mode everywhere. No `any` unless absolutely unavoidable -- use `unknown` and narrow.
- ESM modules throughout (`"type": "module"` in package.json).
- Zod for all external input validation (MCP tool inputs, webhook payloads, env vars).
- No ORM -- use Supabase JS client directly with typed queries.
- Errors: never throw raw strings. Wrap in `new Error(...)`. MCP tools return `{ error: string }` on failure rather than throwing.
- No `console.log` in production paths -- use a structured logger (pino).
- All timestamps stored and compared in UTC. Display in Central Time (America/Chicago) for human-readable output.
- Do not use em dashes anywhere in user-facing text or post content.

---

## What "done" looks like for the first agent run

The agent should complete these in order, committing after each:

1. `pnpm` workspace root `package.json` and `pnpm-workspace.yaml`
2. `packages/types/src/index.ts` -- all shared TypeScript types matching the schema above
3. `packages/db/src/client.ts` -- Supabase client factory
4. `packages/db/src/index.ts` -- re-exports
5. `apps/mcp-server/` -- full implementation of all 10 MCP tools listed above
6. `apps/mcp-server/README.md` -- how to run locally and how to add to Claude Desktop config
7. `apps/worker/src/index.ts` -- polling loop
8. `apps/worker/src/platforms/` -- stub adapters for all 5 platforms (stubs are fine, real API calls in follow-up)
9. `apps/worker/src/webhooks/creatomate.ts` -- webhook handler
10. `apps/dashboard/` -- Next.js app with the queue calendar view
11. `.env.example` -- all vars documented
12. Root `README.md` -- setup instructions

Do not move to the next item until the current one typechecks cleanly.
