-- Step data: per-source hourly buckets (UTC hour starts), the effective hourly
-- series after de-duplication, and per-time-zone daily totals used by history,
-- group leaderboards, challenges and global rankings.
--
-- Sync is idempotent by construction:
--   * every bucket is a per-source *cumulative* hour total, merged with GREATEST,
--     so replaying an upload (or uploading the same hour twice) cannot inflate it;
--   * the effective series is recomputed from the source buckets, never added to;
--   * each upload batch carries a client-generated UUID recorded in sync_batches.

create table public.step_buckets (
  user_id uuid not null references auth.users (id) on delete cascade,
  source_id text not null check (char_length(source_id) between 1 and 80),
  source_kind text not null check (source_kind in ('phone', 'health')),
  bucket_start timestamptz not null
    check (extract(epoch from bucket_start)::bigint % 3600 = 0),
  steps int not null check (steps between 0 and 15000),
  updated_at timestamptz not null default now(),
  primary key (user_id, source_id, bucket_start)
);

create table public.effective_hourly (
  user_id uuid not null references auth.users (id) on delete cascade,
  bucket_start timestamptz not null,
  steps int not null,
  primary key (user_id, bucket_start)
);

-- Daily totals of the effective series, materialised for every time zone the
-- user participates in (own zone + each group/challenge zone).
create table public.user_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  tz text not null,
  day date not null,
  steps int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, tz, day)
);
create index user_daily_board on public.user_daily (tz, day, user_id) include (steps);

create table public.sync_batches (
  user_id uuid not null references auth.users (id) on delete cascade,
  batch_id uuid not null,
  received_at timestamptz not null default now(),
  result jsonb not null,
  primary key (user_id, batch_id)
);

create table public.rest_days (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);

create table public.goal_history (
  user_id uuid not null references auth.users (id) on delete cascade,
  effective_from date not null,
  goal int not null check (goal between 500 and 100000),
  primary key (user_id, effective_from)
);

create table public.user_achievements (
  user_id uuid not null references auth.users (id) on delete cascade,
  key text not null check (char_length(key) <= 60),
  unlocked_on date not null,
  primary key (user_id, key)
);

alter table public.step_buckets enable row level security;
alter table public.effective_hourly enable row level security;
alter table public.user_daily enable row level security;
alter table public.sync_batches enable row level security;
alter table public.rest_days enable row level security;
alter table public.goal_history enable row level security;
alter table public.user_achievements enable row level security;

create policy own_select on public.step_buckets for select to authenticated using (user_id = auth.uid());
create policy own_select on public.effective_hourly for select to authenticated using (user_id = auth.uid());
create policy own_select on public.user_daily for select to authenticated using (user_id = auth.uid());
create policy own_select on public.rest_days for select to authenticated using (user_id = auth.uid());
create policy own_select on public.goal_history for select to authenticated using (user_id = auth.uid());
create policy own_select on public.user_achievements for select to authenticated using (user_id = auth.uid());
create policy own_insert on public.user_achievements for insert to authenticated with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Time zones a user's totals must be materialised in
-- ---------------------------------------------------------------------------
-- (group / challenge tables are created later; this function is replaced in
--  20261117000400 once they exist.)
create or replace function public.user_zones(p_uid uuid)
returns setof text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select time_zone from public.profiles where id = p_uid
$$;

-- Recompute the effective hourly series for a set of hours.
-- Policy (identical to the app's SourceMerger):
--   auto           -> max over all sources in the hour (never a sum)
--   prefer_phone   -> phone sources if they recorded steps in that hour, else max of the rest
--   prefer_health  -> health-platform sources if they recorded steps, else phone
create or replace function public.recompute_effective(p_uid uuid, p_hours timestamptz[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_policy text;
begin
  select source_policy into v_policy from public.profiles where id = p_uid;
  v_policy := coalesce(v_policy, 'auto');

  insert into public.effective_hourly (user_id, bucket_start, steps)
  select p_uid, h.hour,
         case
           when v_policy = 'prefer_phone' and coalesce(max(b.steps) filter (where b.source_kind = 'phone'), 0) > 0
             then max(b.steps) filter (where b.source_kind = 'phone')
           when v_policy = 'prefer_health' and coalesce(max(b.steps) filter (where b.source_kind = 'health'), 0) > 0
             then max(b.steps) filter (where b.source_kind = 'health')
           else coalesce(max(b.steps), 0)
         end
  from unnest(p_hours) as h(hour)
  left join public.step_buckets b on b.user_id = p_uid and b.bucket_start = h.hour
  group by h.hour
  on conflict (user_id, bucket_start) do update set steps = excluded.steps;
end
$$;

-- Recompute daily totals for (tz, day) pairs derived from a set of hours.
create or replace function public.recompute_daily_for_hours(p_uid uuid, p_hours timestamptz[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  with zones as (
    select distinct z as tz from public.user_zones(p_uid) z
  ), days as (
    select distinct zones.tz, (h.hour at time zone zones.tz)::date as day
    from zones cross join unnest(p_hours) as h(hour)
  )
  insert into public.user_daily (user_id, tz, day, steps, updated_at)
  select p_uid, d.tz, d.day,
         coalesce((
           select sum(e.steps)
           from public.effective_hourly e
           where e.user_id = p_uid
             and e.bucket_start >= public.day_start(d.day, d.tz)
             and e.bucket_start < public.day_start(d.day + 1, d.tz)
         ), 0),
         now()
  from days d
  on conflict (user_id, tz, day) do update
    set steps = excluded.steps,
        updated_at = case when public.user_daily.steps is distinct from excluded.steps
                          then now() else public.user_daily.updated_at end;
end
$$;

-- Rebuild a user's daily totals in one zone from a start day (used when the
-- user joins a group/challenge in a new zone, or changes their own zone).
create or replace function public.rebuild_user_daily(p_uid uuid, p_tz text, p_from date)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.user_daily (user_id, tz, day, steps, updated_at)
  select p_uid, p_tz, (e.bucket_start at time zone p_tz)::date, sum(e.steps), now()
  from public.effective_hourly e
  where e.user_id = p_uid and e.bucket_start >= public.day_start(p_from, p_tz)
  group by 3
  on conflict (user_id, tz, day) do update set steps = excluded.steps, updated_at = now();
end
$$;

-- Hook for later migrations to mark leaderboards dirty (replaced in 000400).
create or replace function public.mark_user_boards_dirty(p_uid uuid)
returns void language sql security definer set search_path = public, pg_temp as $$ select $$;

-- ---------------------------------------------------------------------------
-- Upload RPC
-- p_buckets: [{"source_id":"phone:android","source_kind":"phone",
--              "bucket_start":"2026-11-17T07:00:00Z","steps":812}, ...]
-- ---------------------------------------------------------------------------
create or replace function public.upload_step_buckets(p_batch_id uuid, p_buckets jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_prev jsonb;
  v_hours timestamptz[];
  v_accepted int := 0;
  v_clamped int := 0;
  v_rejected int := 0;
  v_max_day int;
  v_result jsonb;
  c_max_hour constant int := 15000;   -- ~250 steps/min for a full hour
  c_max_day constant int := 150000;   -- beyond this a day is flagged for review
begin
  if p_batch_id is null or jsonb_typeof(p_buckets) <> 'array' then
    raise exception 'invalid_payload' using errcode = '22023';
  end if;
  if jsonb_array_length(p_buckets) > 2000 then
    raise exception 'batch_too_large' using errcode = '22023';
  end if;

  -- Idempotent replay: the same batch id returns the original result.
  select result into v_prev from public.sync_batches where user_id = v_uid and batch_id = p_batch_id;
  if found then
    return v_prev || jsonb_build_object('duplicate', true);
  end if;

  perform public.enforce_rate_limit('upload_steps', 240, interval '1 hour');

  if to_regclass('pg_temp._incoming') is null then
    create temp table _incoming (
      source_id text, source_kind text, bucket_start timestamptz, steps int, ok boolean
    ) on commit drop;
  end if;
  truncate _incoming;

  insert into _incoming
  select left(x ->> 'source_id', 80),
         x ->> 'source_kind',
         (x ->> 'bucket_start')::timestamptz,
         (x ->> 'steps')::int,
         true
  from jsonb_array_elements(p_buckets) x;

  update _incoming set ok = false
  where source_id is null or source_id = ''
     or source_kind not in ('phone', 'health')
     or bucket_start is null
     or extract(epoch from bucket_start)::bigint % 3600 <> 0
     or bucket_start > now() + interval '1 hour'
     or bucket_start < now() - interval '400 days'
     or steps is null or steps < 0;
  get diagnostics v_rejected = row_count;

  update _incoming set steps = c_max_hour where ok and steps > c_max_hour;
  get diagnostics v_clamped = row_count;

  -- Collapse duplicates inside one batch, then max-merge into storage.
  insert into public.step_buckets (user_id, source_id, source_kind, bucket_start, steps, updated_at)
  select v_uid, source_id, max(source_kind), bucket_start, max(steps), now()
  from _incoming where ok
  group by source_id, bucket_start
  on conflict (user_id, source_id, bucket_start) do update
    set steps = greatest(public.step_buckets.steps, excluded.steps),
        updated_at = case when excluded.steps > public.step_buckets.steps then now()
                          else public.step_buckets.updated_at end;
  get diagnostics v_accepted = row_count;

  select array_agg(distinct bucket_start) into v_hours from _incoming where ok;

  if v_hours is not null then
    perform public.recompute_effective(v_uid, v_hours);
    perform public.recompute_daily_for_hours(v_uid, v_hours);
    perform public.mark_user_boards_dirty(v_uid);
  end if;

  if v_clamped > 0 then
    update public.profiles set flagged_at = coalesce(flagged_at, now()),
      flag_reason = coalesce(flag_reason, 'hourly_steps_above_limit') where id = v_uid;
  end if;

  select max(d.steps) into v_max_day
  from public.user_daily d join public.profiles p on p.id = d.user_id and d.tz = p.time_zone
  where d.user_id = v_uid and d.day >= current_date - 2;
  if coalesce(v_max_day, 0) > c_max_day then
    update public.profiles set flagged_at = coalesce(flagged_at, now()),
      flag_reason = coalesce(flag_reason, 'daily_steps_above_limit') where id = v_uid;
  end if;

  v_result := jsonb_build_object(
    'accepted', v_accepted, 'clamped', v_clamped, 'rejected', v_rejected,
    'server_time', now());
  insert into public.sync_batches (user_id, batch_id, result) values (v_uid, p_batch_id, v_result);
  return v_result || jsonb_build_object('duplicate', false);
end
$$;

-- Daily history for the signed-in user, in their own zone.
create or replace function public.get_my_daily(p_from date, p_to date)
returns table (day date, steps int)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select d.day, d.steps
  from public.user_daily d
  join public.profiles p on p.id = d.user_id and d.tz = p.time_zone
  where d.user_id = auth.uid() and d.day between p_from and p_to
  order by d.day
$$;

-- Hourly effective series (used to restore history on a new device).
create or replace function public.get_my_hourly(p_from timestamptz, p_to timestamptz)
returns table (bucket_start timestamptz, steps int)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select e.bucket_start, e.steps from public.effective_hourly e
  where e.user_id = auth.uid() and e.bucket_start >= p_from and e.bucket_start < p_to
  order by e.bucket_start
$$;

-- When the user changes their zone or source policy, rebuild derived data.
create or replace function public.profiles_after_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hours timestamptz[];
begin
  if new.source_policy is distinct from old.source_policy then
    select array_agg(distinct bucket_start) into v_hours
    from public.step_buckets where user_id = new.id and bucket_start >= now() - interval '400 days';
    if v_hours is not null then
      perform public.recompute_effective(new.id, v_hours);
      perform public.recompute_daily_for_hours(new.id, v_hours);
    end if;
  end if;
  if new.time_zone is distinct from old.time_zone then
    perform public.rebuild_user_daily(new.id, new.time_zone, current_date - 400);
  end if;
  if new.time_zone is distinct from old.time_zone
     or new.source_policy is distinct from old.source_policy
     or new.steps_private is distinct from old.steps_private then
    perform public.mark_user_boards_dirty(new.id);
  end if;
  if new.daily_goal is distinct from old.daily_goal then
    insert into public.goal_history (user_id, effective_from, goal)
    values (new.id, public.today_in(new.time_zone), new.daily_goal)
    on conflict (user_id, effective_from) do update set goal = excluded.goal;
  end if;
  return new;
end
$$;

create trigger profiles_after_update
after update on public.profiles
for each row execute function public.profiles_after_update();

-- Rest days: at most 2 per ISO week, only today or future (in the user's zone),
-- so a missed goal cannot be retroactively "rescued".
create or replace function public.set_rest_day(p_day date, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_today date;
  v_count int;
begin
  select public.today_in(time_zone) into v_today from public.profiles where id = v_uid;
  if p_day < v_today then
    raise exception 'rest_day_in_past' using errcode = '22023';
  end if;
  if p_day > v_today + 60 then
    raise exception 'rest_day_too_far' using errcode = '22023';
  end if;
  if p_on then
    select count(*) into v_count from public.rest_days
    where user_id = v_uid and date_trunc('week', day) = date_trunc('week', p_day) and day <> p_day;
    if v_count >= 2 then
      raise exception 'rest_day_week_limit' using errcode = '22023';
    end if;
    insert into public.rest_days (user_id, day) values (v_uid, p_day) on conflict do nothing;
  else
    delete from public.rest_days where user_id = v_uid and day = p_day;
  end if;
end
$$;
