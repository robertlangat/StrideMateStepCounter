-- StrideMate core: profiles, helpers, rate limiting.
-- All client access goes through RLS-protected tables or SECURITY DEFINER RPCs
-- that check auth.uid(). No service-role key is ever shipped in the app.

create type public.group_role as enum ('owner', 'admin', 'member');
create type public.message_kind as enum ('text', 'cheer', 'taunt', 'system');

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Returns the name if it is a valid IANA time zone known to Postgres, else NULL.
create or replace function public.valid_tz(p_tz text)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select name from pg_timezone_names where name = p_tz limit 1
$$;

-- Local calendar date "now" in a time zone.
create or replace function public.today_in(p_tz text)
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select (now() at time zone p_tz)::date
$$;

-- Start instant of a local calendar day in a time zone.
create or replace function public.day_start(p_day date, p_tz text)
returns timestamptz
language sql
stable
set search_path = public, pg_temp
as $$
  select (p_day::timestamp) at time zone p_tz
$$;

create or replace function public.require_uid()
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v uuid := auth.uid();
begin
  if v is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  return v;
end
$$;

-- Unambiguous invite codes (no 0/O/1/I/L). 32-char alphabet => 5 bits per char,
-- drawn from gen_random_uuid() bytes, skipping the fixed version/variant bytes.
create or replace function public.random_code(n int default 10)
returns text
language plpgsql
volatile
set search_path = public, pg_temp
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789A';
  b bytea;
  out_code text := '';
  i int := 0;
begin
  while char_length(out_code) < n loop
    b := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    for i in 0..15 loop
      continue when i in (6, 8);
      out_code := out_code || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
      exit when char_length(out_code) >= n;
    end loop;
  end loop;
  return out_code;
end
$$;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Walker'
    check (char_length(btrim(display_name)) between 1 and 40),
  avatar_emoji text check (avatar_emoji is null or char_length(avatar_emoji) <= 8),
  country_code text check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  global_rankings_opt_in boolean not null default false,
  -- Master switch: when true, nobody else ever sees this user's step totals.
  steps_private boolean not null default false,
  time_zone text not null default 'UTC',
  daily_goal int not null default 8000 check (daily_goal between 500 and 100000),
  -- How overlapping sources are combined per hour: see docs/STEP_SOURCES.md
  source_policy text not null default 'auto'
    check (source_policy in ('auto', 'prefer_phone', 'prefer_health')),
  flagged_at timestamptz,
  flag_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.profiles_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if public.valid_tz(new.time_zone) is null then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;
  new.display_name := btrim(new.display_name);
  new.updated_at := now();
  return new;
end
$$;

create trigger profiles_before_write
before insert or update on public.profiles
for each row execute function public.profiles_before_write();

-- Create a profile row automatically for every new auth user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(btrim(left(new.raw_user_meta_data ->> 'display_name', 40)), ''),
      'Walker ' || upper(left(replace(new.id::text, '-', ''), 4))
    )
  )
  on conflict (id) do nothing;
  return new;
end
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;

create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- Rate limiting (sliding window, per user + action)
-- ---------------------------------------------------------------------------

create table public.rate_events (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  action text not null,
  at timestamptz not null default now()
);
create index rate_events_lookup on public.rate_events (user_id, action, at desc);
alter table public.rate_events enable row level security; -- no policies: internal only

create or replace function public.enforce_rate_limit(p_action text, p_max int, p_window interval)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_count int;
begin
  -- Serialize concurrent calls for the same user/action so bursts cannot slip through.
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || ':' || p_action, 0));
  select count(*) into v_count
  from public.rate_events
  where user_id = v_uid and action = p_action and at > now() - p_window;
  if v_count >= p_max then
    raise exception 'rate_limited:%', p_action using errcode = 'P0429',
      hint = 'Too many requests. Please wait and try again.';
  end if;
  insert into public.rate_events (user_id, action) values (v_uid, p_action);
end
$$;

create or replace function public.prune_rate_events()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.rate_events where at < now() - interval '2 days'
$$;
