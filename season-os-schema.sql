-- ═══════════════════════════════════════════════════════════════
-- Season OS — Postgres schema (written for Supabase)
--
-- Run this in the Supabase SQL editor. It assumes Supabase Auth,
-- so every table hangs off auth.users and is protected by RLS.
-- If you use plain Postgres instead, drop the RLS blocks and
-- replace auth.uid() with your own session user id.
-- ═══════════════════════════════════════════════════════════════

create extension if not exists "pgcrypto";

-- ── the season itself ─────────────────────────────────────────
create table season (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  name        text not null default 'Season 01',
  start_date  date not null default current_date,
  length_days int  not null default 183,
  created_at  timestamptz not null default now()
);

-- ── bets and tasks ────────────────────────────────────────────
-- pillar is an enum, not free text: the whole point is that
-- everything ladders up to exactly four bets.
create type pillar as enum ('ip','net','build','body');

create table todo (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  pillar     pillar not null,
  body       text not null,
  done       boolean not null default false,
  done_at    timestamptz,
  created_at timestamptz not null default now()
);
create index on todo (user_id, pillar) where not done;

-- ── one row per day ───────────────────────────────────────────
-- habits and lifts stay jsonb: they're a checklist whose shape
-- you will change ten times this season. Don't model them yet.
create table day (
  user_id uuid not null references auth.users on delete cascade,
  on_date date not null,
  habits  jsonb not null default '{}'::jsonb,
  lifts   jsonb not null default '{}'::jsonb,
  water   int  not null default 0 check (water between 0 and 6),
  trained boolean not null default false,
  primary key (user_id, on_date)
);

-- ── 15-minute work cycles ─────────────────────────────────────
create type cycle_result as enum ('hit','partly','miss');

create table cycle (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  pillar     pillar,
  target     text not null,
  first_move text,
  hazard     text,
  result     cycle_result,
  note       text,
  started_at timestamptz not null,
  ended_at   timestamptz
);
create index on cycle (user_id, started_at desc);

-- ── morning pages ─────────────────────────────────────────────
-- words is generated, so you can never disagree with yourself
-- about the count. Rough CJK + latin token estimate.
create table page (
  user_id uuid not null references auth.users on delete cascade,
  on_date date not null,
  body    text not null default '',
  words   int generated always as (
             coalesce(array_length(regexp_split_to_array(trim(body), '\s+'), 1), 0)
           ) stored,
  primary key (user_id, on_date)
);

-- ── the people file ───────────────────────────────────────────
create type tier as enum ('inner','weak','want');

create table person (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  name         text not null,
  context      text,
  tier         tier not null default 'weak',
  cadence_days int  not null default 30,
  charges      boolean not null default false,  -- ⚡ refills your battery
  next_move    text,
  created_at   timestamptz not null default now()
);

-- Touches are their own table, not a last_touch column. You want
-- the history: how a relationship actually moved over six months.
create table touch (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  person_id   uuid not null references person on delete cascade,
  happened_on date not null default current_date,
  kind        text,   -- coffee / call / event / message
  note        text
);
create index on touch (person_id, happened_on desc);

-- Who is overdue, computed rather than stored.
create view person_due as
select p.*,
       t.last_touch,
       current_date - t.last_touch                       as days_since,
       coalesce(current_date - t.last_touch, 9999)
         >= p.cadence_days                               as is_due
from person p
left join lateral (
  select max(happened_on) as last_touch
  from touch where touch.person_id = p.id
) t on true;

-- ── rooms you host ────────────────────────────────────────────
create type event_status as enum ('idea','planning','dated','held');

create table event (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references auth.users on delete cascade,
  name      text not null,
  cn_name   text,
  blurb     text,
  cadence   text,
  headcount text,
  status    event_status not null default 'idea',
  held_on   date
);

-- Who came to what — this is the table that turns hosting into a network.
create table attendance (
  event_id  uuid not null references event on delete cascade,
  person_id uuid not null references person on delete cascade,
  held_on   date not null,
  primary key (event_id, person_id, held_on)
);

-- ── weekly rollups ────────────────────────────────────────────
create table week (
  user_id    uuid not null references auth.users on delete cascade,
  week_start date not null,               -- always a Monday
  story      jsonb not null default '{}'::jsonb,   -- {open, turn, learn}
  leads      jsonb not null default '{}'::jsonb,   -- {met, sourced, shipped, asked}
  tape       jsonb not null default '{}'::jsonb,   -- {shoulder, waist, hip, thigh, weight}
  primary key (user_id, week_start)
);

-- ── milestones ────────────────────────────────────────────────
create table milestone (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  title       text not null,
  kind        text not null default 'pinned',  -- 'pinned' | 'unlocked'
  target_date date,
  achieved_on date
);

-- ═══════════════════════════════════════════════════════════════
-- Row Level Security — do this before you put anything real in.
-- Without it, your anon key is a public read of your whole life.
-- ═══════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array['season','todo','day','cycle','page','person',
                           'touch','event','week','milestone']
  loop
    execute format('alter table %I enable row level security', t);
    execute format($f$
      create policy "own rows" on %I
        for all
        using (user_id = auth.uid())
        with check (user_id = auth.uid())
    $f$, t);
  end loop;
end $$;

-- attendance has no user_id; it inherits from its event.
alter table attendance enable row level security;
create policy "own rows" on attendance for all
  using (exists (select 1 from event e where e.id = event_id and e.user_id = auth.uid()))
  with check (exists (select 1 from event e where e.id = event_id and e.user_id = auth.uid()));


-- ═══════════════════════════════════════════════════════════════
-- Queries worth having on day one
-- ═══════════════════════════════════════════════════════════════

-- Where did my focus actually go this week, by bet?
select pillar, count(*) * 15 / 60.0 as hours
from cycle
where user_id = auth.uid()
  and result <> 'miss'
  and started_at >= date_trunc('week', now())
group by pillar
order by hours desc;

-- Who is overdue right now, most neglected first?
select name, tier, days_since, cadence_days, next_move
from person_due
where user_id = auth.uid() and is_due
order by days_since desc nulls first;

-- Who charges my battery and is also overdue? (the "text one person" query)
select name, next_move from person_due
where user_id = auth.uid() and charges and is_due
order by random() limit 1;

-- Do the mornings I write predict the days I focus?
select p.words > 100 as wrote_pages,
       round(avg(c.n), 1) as avg_cycles
from page p
left join lateral (
  select count(*) as n from cycle
  where cycle.user_id = p.user_id
    and cycle.result <> 'miss'
    and cycle.started_at::date = p.on_date
) c on true
where p.user_id = auth.uid()
group by 1;
