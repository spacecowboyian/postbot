-- ============================================================
-- PostBot - Initial Schema Migration
-- 001_initial_schema.sql
-- ============================================================

-- Extensions
create extension if not exists "uuid-ossp";
create extension if not exists "pg_cron"; -- for cleanup sweeps

-- ============================================================
-- CHANNELS
-- One row per content channel (OIO, Tiny Prints, Personal)
-- ============================================================
create table channels (
  id              uuid primary key default uuid_generate_v4(),
  name            text not null,
  slug            text not null unique,              -- 'oio' | 'tiny-prints' | 'personal'
  voice_config    text not null,                     -- full system prompt for Claude
  audience_notes  text,                              -- who we're talking to
  hashtag_notes   text,                              -- guidance for Claude on tag selection
  default_platforms text[] not null default '{}',    -- ['instagram','youtube']
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

comment on column channels.voice_config is
  'Full Claude system prompt for this channel including tone, rules, and persona.';

-- ============================================================
-- ACCOUNTS
-- Platform credentials reference per channel
-- Credentials live in env vars on the worker, referenced by slug
-- ============================================================
create table accounts (
  id              uuid primary key default uuid_generate_v4(),
  channel_id      uuid not null references channels(id) on delete cascade,
  platform        text not null,                     -- 'instagram' | 'youtube' | 'threads' | 'x'
  handle          text not null,                     -- '@OIORacing'
  credentials_ref text not null,                     -- env var name on worker e.g. 'OIO_INSTAGRAM_TOKEN'
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  unique(channel_id, platform)
);

-- ============================================================
-- QUEUE RULES
-- Per-channel, per-platform posting cadence rules
-- Claude reads these via MCP to propose scheduling
-- ============================================================
create table queue_rules (
  id                  uuid primary key default uuid_generate_v4(),
  channel_id          uuid not null references channels(id) on delete cascade,
  platform            text not null,
  min_gap_hours       int not null default 12,       -- min hours between posts on this platform
  max_per_day         int not null default 2,
  preferred_days      text[] default '{}',           -- ['monday','wednesday','friday']
  preferred_windows   jsonb default '[]',            -- [{"start":"17:00","end":"20:00"}]
  created_at          timestamptz not null default now(),
  unique(channel_id, platform)
);

-- ============================================================
-- HASHTAGS
-- Per-channel hashtag bank with performance tracking
-- Claude selects from this pool when composing posts
-- ============================================================
create table hashtags (
  id              uuid primary key default uuid_generate_v4(),
  channel_id      uuid not null references channels(id) on delete cascade,
  tag             text not null,                     -- '#scca' (include the #)
  category        text,                              -- 'racing' | 'car' | 'event' | 'product' etc
  total_uses      int not null default 0,
  avg_reach       numeric(10,2),
  avg_engagement  numeric(5,4),                      -- ratio 0.0000-1.0000
  last_used       timestamptz,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  unique(channel_id, tag)
);

-- ============================================================
-- POSTS
-- Core table. One row per post batch (may target multiple platforms).
-- Media is JSONB to support images, video, and mixed future types.
-- ============================================================
create table posts (
  id                  uuid primary key default uuid_generate_v4(),
  channel_id          uuid not null references channels(id) on delete cascade,

  -- Content
  raw_text            text,                          -- what Ian typed/said
  optimized_text      text,                          -- Claude's rewrite
  alt_text            text,                          -- accessibility / SEO

  -- Media
  -- Array of media objects. Schema per object:
  -- {
  --   type: 'video' | 'image',
  --   raw_path: text,                (Supabase Storage or R2 path)
  --   processed_path: text,          (after Creatomate or Sharp)
  --   thumbnail_path: text,
  --   duration_seconds: int,         (video only)
  --   creatomate_job_id: text,       (video only)
  --   creatomate_status: text,       (queued|rendering|done|failed)
  --   platform_variants: {           (platform -> processed path)
  --     instagram: text,
  --     youtube: text,
  --     threads: text,
  --     x: text
  --   },
  --   storage_cleared_at: timestamptz
  -- }
  media               jsonb not null default '[]',

  -- Targeting
  target_platforms    text[] not null default '{}',  -- subset of channel default_platforms
  platform_overrides  jsonb default '{}',            -- per-platform text tweaks if needed

  -- Scheduling metadata
  mood                text,                          -- 'hype' | 'informational' | 'community' | 'product'
  campaign_tag        text,                          -- 'bmw2002-reveal' | 'flex-plate-launch'
  embargoed_until     timestamptz,                   -- do not post before this time
  scheduled_at        timestamptz,                   -- Claude-proposed, you-approved time
  hashtags_used       text[] default '{}',           -- subset selected from hashtags table

  -- Status lifecycle
  -- draft -> pending_approval -> approved -> posting -> posted | failed | cancelled
  status              text not null default 'draft',

  -- Post results
  posted_at           timestamptz,
  platform_post_ids   jsonb default '{}',            -- {instagram: 'xxx', youtube: 'yyy'}
  post_errors         jsonb default '{}',            -- {platform: 'error message'}

  -- Storage cleanup
  is_evergreen        boolean not null default false,
  storage_cleared_at  timestamptz,

  -- Audit
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on column posts.media is
  'JSONB array of media objects. Supports video and image. See migration comment for full schema.';

comment on column posts.platform_overrides is
  'Optional per-platform text variations. e.g. {"x": "slightly different caption"}';  

-- ============================================================
-- CREATOMATE JOBS
-- Tracks async render jobs. Webhook updates rows here.
-- Decoupled from posts.media so we have a clean audit trail.
-- ============================================================
create table creatomate_jobs (
  id              uuid primary key default uuid_generate_v4(),
  post_id         uuid not null references posts(id) on delete cascade,
  job_id          text not null unique,              -- Creatomate's render ID
  template_id     text,                              -- Creatomate template if used
  platform        text not null,                     -- which variant this job produces
  input_url       text not null,                     -- source file URL sent to Creatomate
  output_url      text,                              -- filled in on webhook complete
  operations      jsonb not null default '{}',       -- what we asked for: trim, overlay, etc
  status          text not null default 'queued',    -- queued|rendering|done|failed
  error           text,
  started_at      timestamptz,
  completed_at    timestamptz,
  created_at      timestamptz not null default now()
);

-- ============================================================
-- POST METRICS
-- Engagement data fetched back from platform APIs after posting.
-- Used to train Claude's scheduling and hashtag suggestions.
-- ============================================================
create table post_metrics (
  id              uuid primary key default uuid_generate_v4(),
  post_id         uuid not null references posts(id) on delete cascade,
  platform        text not null,
  reach           int,
  impressions     int,
  likes           int,
  comments        int,
  shares          int,
  saves           int,
  plays           int,                               -- video only
  watch_time_avg  numeric(8,2),                      -- seconds, video only
  fetched_at      timestamptz not null default now(),
  unique(post_id, platform, fetched_at)
);

-- ============================================================
-- INDEXES
-- ============================================================

-- Posts: worker polling query
create index posts_status_scheduled_idx
  on posts(status, scheduled_at)
  where status = 'approved';

-- Posts: queue viewer by channel
create index posts_channel_status_idx
  on posts(channel_id, status, scheduled_at desc);

-- Posts: cleanup sweep
create index posts_cleanup_idx
  on posts(posted_at, storage_cleared_at)
  where storage_cleared_at is null and status = 'posted';

-- Hashtags: Claude's tag lookup
create index hashtags_channel_category_idx
  on hashtags(channel_id, category, avg_engagement desc nulls last);

-- Creatomate: webhook lookup by job_id
create index creatomate_job_id_idx
  on creatomate_jobs(job_id);

-- Metrics: performance queries
create index post_metrics_post_platform_idx
  on post_metrics(post_id, platform);

-- ============================================================
-- UPDATED_AT TRIGGER
-- ============================================================
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger posts_updated_at
  before update on posts
  for each row execute function set_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY
-- All tables locked down. Service role key (worker + MCP)
-- bypasses RLS. Anon key gets nothing.
-- ============================================================
alter table channels         enable row level security;
alter table accounts         enable row level security;
alter table queue_rules      enable row level security;
alter table hashtags         enable row level security;
alter table posts            enable row level security;
alter table creatomate_jobs  enable row level security;
alter table post_metrics     enable row level security;

-- Service role can do everything (worker, MCP server)
create policy "service role full access" on channels
  using (auth.role() = 'service_role');
create policy "service role full access" on accounts
  using (auth.role() = 'service_role');
create policy "service role full access" on queue_rules
  using (auth.role() = 'service_role');
create policy "service role full access" on hashtags
  using (auth.role() = 'service_role');
create policy "service role full access" on posts
  using (auth.role() = 'service_role');
create policy "service role full access" on creatomate_jobs
  using (auth.role() = 'service_role');
create policy "service role full access" on post_metrics
  using (auth.role() = 'service_role');

-- ============================================================
-- STORAGE BUCKETS
-- Run these in Supabase dashboard or via storage API
-- ============================================================

-- Raw uploads from Ian (large, private)
-- insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
-- values ('media-raw', 'media-raw', false, 5368709120, -- 5GB
--   array['video/mp4','video/quicktime','video/x-msvideo',
--         'image/jpeg','image/png','image/heic','image/webp']);

-- Processed outputs from Creatomate / Sharp (public CDN URLs for platform APIs)
-- insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
-- values ('media-processed', 'media-processed', true, 1073741824, -- 1GB
--   array['video/mp4','image/jpeg','image/png','image/webp']);

-- Evergreen assets kept long-term (public)
-- insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
-- values ('media-assets', 'media-assets', true, 1073741824,
--   array['video/mp4','image/jpeg','image/png','image/webp']);

-- Thumbnails (public, small)
-- insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
-- values ('media-thumbs', 'media-thumbs', true, 10485760, -- 10MB
--   array['image/jpeg','image/png','image/webp']);

-- ============================================================
-- SEED: CHANNELS
-- ============================================================
insert into channels (name, slug, voice_config, audience_notes, hashtag_notes, default_platforms)
values
(
  'OIO Racing',
  'oio',
  'You are the voice of OIO Racing (@OIORacing), an SCCA autocross and motorsport channel run by Ian. Your audience is car enthusiasts, autocross competitors, and motorsport fans. Write with energy and technical credibility. Be punchy -- short sentences hit harder. Use correct motorsport terminology. Always tag the event when known. Never use em dashes.',
  'Car enthusiasts, SCCA autocross competitors, DIY builders, BMW fans, motorsport watchers. They want authenticity over polish.',
  'Prioritize event-specific tags first, then car/series tags, then broad reach tags. Aim for 8-12 tags. Mix niche and broad.',
  array['instagram','youtube']
),
(
  'Tiny Prints',
  'tiny-prints',
  'You are the voice of Tiny Prints, Ian''s 3D printing business. Your audience is makers, hobbyists, and people looking for custom 3D-printed parts and products. Write with enthusiasm for the craft. Be helpful and specific about materials and use cases. Highlight precision and customization. Never use em dashes.',
  'Makers, hobbyists, RC car builders, automotive enthusiasts needing custom parts, gift buyers. They respond to process content and finished results.',
  'Mix maker community tags with product-specific tags. Include material tags when relevant (PLA, PETG, TPU). Aim for 10-15 tags.',
  array['instagram']
),
(
  'Personal',
  'personal',
  'You are writing for Ian''s personal account. Casual, genuine, first-person. This is his personal feed -- friends, colleagues, and the overlap between his professional and personal worlds. No hard sell. Share the moment. Never use em dashes.',
  'Friends, colleagues, motorsport community, design/tech community. Casual tone, genuine moments.',
  'Keep it light on hashtags -- 3 to 5 max. Prefer community over reach.',
  array['instagram','threads']
);

-- ============================================================
-- SEED: QUEUE RULES
-- ============================================================
insert into queue_rules (channel_id, platform, min_gap_hours, max_per_day, preferred_days, preferred_windows)
select id, 'instagram', 18, 1,
  array['tuesday','thursday','saturday','sunday'],
  '[{"start":"17:00","end":"20:00"}]'::jsonb
from channels where slug = 'oio';

insert into queue_rules (channel_id, platform, min_gap_hours, max_per_day, preferred_days, preferred_windows)
select id, 'youtube', 72, 1,
  array['saturday','sunday'],
  '[{"start":"10:00","end":"13:00"}]'::jsonb
from channels where slug = 'oio';

insert into queue_rules (channel_id, platform, min_gap_hours, max_per_day, preferred_days, preferred_windows)
select id, 'instagram', 24, 1,
  array['monday','wednesday','friday'],
  '[{"start":"11:00","end":"13:00"},{"start":"18:00","end":"20:00"}]'::jsonb
from channels where slug = 'tiny-prints';

insert into queue_rules (channel_id, platform, min_gap_hours, max_per_day, preferred_days, preferred_windows)
select id, 'instagram', 48, 1,
  array['friday','saturday','sunday'],
  '[{"start":"10:00","end":"21:00"}]'::jsonb
from channels where slug = 'personal';

insert into queue_rules (channel_id, platform, min_gap_hours, max_per_day, preferred_days, preferred_windows)
select id, 'threads', 48, 1,
  array['monday','tuesday','wednesday','thursday','friday'],
  '[{"start":"08:00","end":"09:30"},{"start":"12:00","end":"13:00"}]'::jsonb
from channels where slug = 'personal';

-- ============================================================
-- SEED: HASHTAGS (OIO Racing)
-- ============================================================
insert into hashtags (channel_id, tag, category)
select id, unnest(array[
  -- Events / Series
  '#scca','#sccaautocross','#kcregion','#autocross','#autox',
  '#timeattack','#trackday','#motorsport','#racing',
  -- Car specific
  '#bmw','#bmw2002','#e10','#classicbmw','#vintagebmw',
  '#bimmer','#bimmerpost','#bmwclassic',
  -- Build / wrench
  '#carstagram','#carsofinstagram','#carspotting',
  '#enginebay','#carbuild','#wrenching','#garagebuild',
  '#diy','#carmod',
  -- Broad reach
  '#cargram','#carlovers','#carlife','#instacar',
  '#carphotography','#automotivephotography',
  '#weekendracer','#grassrootsracing','#clubracing'
]), 'racing'
from channels where slug = 'oio';

-- ============================================================
-- SEED: HASHTAGS (Tiny Prints)
-- ============================================================
insert into hashtags (channel_id, tag, category)
select id, unnest(array[
  -- Core 3D printing
  '#3dprinting','#3dprint','#3dprinted','#3dprintingcommunity',
  '#fdm','#pla','#petg','#tpu','#resinprint',
  -- Maker culture
  '#maker','#makerspace','#makersofinstagram',
  '#diy','#diycommunity','#handmade',
  -- Automotive / RC crossover
  '#rccar','#rclife','#rcauto','#customparts',
  '#automotiveparts','#carsofinstagram',
  -- Design
  '#productdesign','#cad','#fusion360','#3ddesign',
  '#customdesign','#prototypedesign',
  -- Commerce
  '#shopsmall','#smallbusiness','#etsy','#custommade',
  '#uniquegifts','#giftideas','#supportsmallbusiness'
]), 'maker'
from channels where slug = 'tiny-prints';

-- ============================================================
-- SEED: HASHTAGS (Personal)
-- ============================================================
insert into hashtags (channel_id, tag, category)
select id, unnest(array[
  '#kansascity','#kcmo','#racing','#maker','#design',
  '#weekendvibes','#carsandcoffee'
]), 'general'
from channels where slug = 'personal';

