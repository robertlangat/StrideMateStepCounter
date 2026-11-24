-- Challenges, Mystery Mode, server-maintained group/challenge rankings, CSV export.
--
-- VISIBILITY MODEL (enforced only here, server-side):
--   A viewer can see another user's steps only if
--     * the owner has not set profiles.steps_private, and
--     * the owner shares steps with that group (group_members.share_steps).
--   Mystery Mode: while a user participates in an *active* Mystery Mode challenge,
--   everything they walked since the start of the current day in that challenge's
--   zone is hidden from everyone else, everywhere (group boards, challenge boards,
--   global boards, CSV exports, notifications), until the day ends in that zone.
--   That instant is the user's "visibility cutoff". Users see their own live totals.
--
-- RANKS: competition ranking ("1, 2, 2, 4"): equal step totals share a rank.
--   Within a tie, rows are listed in a stable order (user id). Pagination is keyset
--   on (rank, user_id). Rankings are recomputed by refresh_dirty_boards() (pg_cron,
--   every minute) for boards whose members uploaded; reads never sort the whole group.
--
-- LATE UPLOADS / FINALITY: any upload for a day re-scores the boards it touches.
--   A dated challenge becomes FINAL at (end date + 1 day, 00:00 in its zone) +
--   grace_hours (default 48h). After that its standings are frozen; later uploads
--   still update the user's personal history but never the final results.

create table public.challenges (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  description text check (description is null or char_length(description) <= 500),
  time_zone text not null,
  starts_on date not null,
  ends_on date,
  mystery_mode boolean not null default false,
  daily_target int check (daily_target is null or daily_target between 500 and 100000),
  grace_hours int not null default 48 check (grace_hours between 0 and 168),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  last_notice_day date,
  check (ends_on is null or ends_on >= starts_on),
  check (ends_on is null or ends_on - starts_on <= 366)
);
create index challenges_group on public.challenges (group_id);
create index challenges_open on public.challenges (finalized_at) where finalized_at is null;

create table public.challenge_participants (
  challenge_id uuid not null references public.challenges (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (challenge_id, user_id)
);
create index challenge_participants_user on public.challenge_participants (user_id);

-- Standings as other participants are allowed to see them.
create table public.challenge_standings (
  challenge_id uuid not null references public.challenges (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  steps bigint not null,
  rank int,                       -- null when the participant does not share steps
  visible boolean not null,
  computed_at timestamptz not null default now(),
  primary key (challenge_id, user_id)
);
create index challenge_standings_page on public.challenge_standings (challenge_id, rank, user_id) where visible;

create table public.challenge_final_daily (
  challenge_id uuid not null references public.challenges (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  steps int not null,
  primary key (challenge_id, user_id, day)
);
alter table public.challenge_final_daily enable row level security; -- RPC only

create table public.group_rankings (
  group_id uuid not null references public.groups (id) on delete cascade,
  period text not null check (period in ('day', 'week', 'month')),
  period_start date not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  steps bigint not null,
  rank int not null,
  computed_at timestamptz not null default now(),
  primary key (group_id, period, period_start, user_id)
);
create index group_rankings_page on public.group_rankings (group_id, period, period_start, rank, user_id);

create table public.board_dirty (
  kind text not null check (kind in ('group', 'challenge')),
  id uuid not null,
  marked_at timestamptz not null default now(),
  primary key (kind, id)
);

alter table public.challenges enable row level security;
alter table public.challenge_participants enable row level security;
alter table public.challenge_standings enable row level security;  -- no policies: RPC only
alter table public.group_rankings enable row level security;       -- no policies: RPC only
alter table public.board_dirty enable row level security;

create policy challenges_member_select on public.challenges for select to authenticated
  using (public.is_group_member(group_id));
create policy participants_self_select on public.challenge_participants for select to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Zones, dirtiness, joins
-- ---------------------------------------------------------------------------
create or replace function public.user_zones(p_uid uuid)
returns setof text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select time_zone from public.profiles where id = p_uid
  union
  select g.time_zone from public.group_members m join public.groups g on g.id = m.group_id where m.user_id = p_uid
  union
  select c.time_zone from public.challenge_participants cp join public.challenges c on c.id = cp.challenge_id
  where cp.user_id = p_uid and c.finalized_at is null
$$;

create or replace function public.mark_group_dirty(p_group uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.board_dirty (kind, id) values ('group', p_group) on conflict do nothing
$$;

create or replace function public.mark_user_boards_dirty(p_uid uuid)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.board_dirty (kind, id)
  select 'group', group_id from public.group_members where user_id = p_uid
  union
  select 'challenge', cp.challenge_id from public.challenge_participants cp
  join public.challenges c on c.id = cp.challenge_id
  where cp.user_id = p_uid and c.finalized_at is null
  on conflict do nothing
$$;

create or replace function public.on_member_joined(p_group uuid, p_uid uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tz text;
begin
  select time_zone into v_tz from public.groups where id = p_group;
  perform public.rebuild_user_daily(p_uid, v_tz, current_date - 40);
  perform public.mark_group_dirty(p_group);
end
$$;

-- ---------------------------------------------------------------------------
-- Mystery Mode cut-offs
-- ---------------------------------------------------------------------------
-- A challenge is "active" from its start day through its end day, in its zone.
create or replace function public.challenge_is_active(c public.challenges)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select c.finalized_at is null
     and c.starts_on <= public.today_in(c.time_zone)
     and (c.ends_on is null or c.ends_on >= public.today_in(c.time_zone))
$$;

-- Earliest "start of today" across a user's active Mystery Mode challenges.
create or replace view public.mystery_cutoffs
with (security_invoker = true) as
select cp.user_id,
       min(public.day_start(public.today_in(c.time_zone), c.time_zone)) as cutoff
from public.challenge_participants cp
join public.challenges c on c.id = cp.challenge_id
where c.mystery_mode and public.challenge_is_active(c)
group by cp.user_id;
revoke all on public.mystery_cutoffs from anon, authenticated;

create or replace function public.visibility_cutoff(p_uid uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select cutoff from public.mystery_cutoffs where user_id = p_uid), 'infinity'::timestamptz)
$$;

-- Steps of p_uid in [p_from, p_to] (local days in p_tz) recorded before p_cut.
create or replace function public.visible_steps(p_uid uuid, p_tz text, p_from date, p_to date, p_cut timestamptz)
returns bigint
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_cut_day date;
  v_full bigint;
  v_part bigint := 0;
begin
  if p_cut = 'infinity'::timestamptz then
    select coalesce(sum(steps), 0) into v_full from public.user_daily
    where user_id = p_uid and tz = p_tz and day between p_from and p_to;
    return v_full;
  end if;
  v_cut_day := (p_cut at time zone p_tz)::date;
  select coalesce(sum(steps), 0) into v_full from public.user_daily
  where user_id = p_uid and tz = p_tz and day between p_from and least(p_to, v_cut_day - 1);
  if v_cut_day between p_from and p_to then
    select coalesce(sum(steps), 0) into v_part from public.effective_hourly
    where user_id = p_uid and bucket_start >= public.day_start(v_cut_day, p_tz) and bucket_start < p_cut;
  end if;
  return v_full + v_part;
end
$$;

-- Set-based version of visible_steps for many users at once (used by the
-- refresh jobs; ~O(rows) instead of one query per member).
create or replace function public.visible_totals(p_users uuid[], p_tz text, p_from date, p_to date,
                                                 p_board_cut timestamptz default 'infinity')
returns table (user_id uuid, steps bigint)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with u as (
    select x.uid, least(p_board_cut, coalesce(mc.cutoff, 'infinity'::timestamptz)) as cut
    from unnest(p_users) as x(uid)
    left join public.mystery_cutoffs mc on mc.user_id = x.uid
  ), uc as (
    select uid, cut,
           case when cut = 'infinity'::timestamptz then null else (cut at time zone p_tz)::date end as cut_day
    from u
  ), full_days as (
    select uc.uid, sum(ud.steps) as s
    from uc join public.user_daily ud
      on ud.user_id = uc.uid and ud.tz = p_tz and ud.day between p_from and p_to
     and (uc.cut_day is null or ud.day < uc.cut_day)
    group by uc.uid
  ), part as (
    select uc.uid, sum(e.steps) as s
    from uc join public.effective_hourly e
      on e.user_id = uc.uid
     and e.bucket_start >= (uc.cut_day::timestamp at time zone p_tz)
     and e.bucket_start < uc.cut
    where uc.cut_day between p_from and p_to
    group by uc.uid
  )
  select uc.uid, (coalesce(f.s, 0) + coalesce(pt.s, 0))::bigint
  from uc left join full_days f on f.uid = uc.uid left join part pt on pt.uid = uc.uid
$$;

-- ---------------------------------------------------------------------------
-- Ranking refresh
-- ---------------------------------------------------------------------------
create or replace function public.period_bounds(p_period text, p_day date)
returns table (period_start date, period_end date)
language sql
immutable
as $$
  select case p_period when 'day' then p_day
                       when 'week' then date_trunc('week', p_day)::date
                       else date_trunc('month', p_day)::date end,
         case p_period when 'day' then p_day
                       when 'week' then (date_trunc('week', p_day) + interval '6 days')::date
                       else (date_trunc('month', p_day) + interval '1 month - 1 day')::date end
$$;

create or replace function public.refresh_group_rankings(p_group uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tz text;
  v_today date;
  v_users uuid[];
  r record;
begin
  select time_zone into v_tz from public.groups where id = p_group;
  if v_tz is null then return; end if;
  v_today := public.today_in(v_tz);
  -- Members who let this group see their steps.
  select coalesce(array_agg(m.user_id), '{}') into v_users
  from public.group_members m join public.profiles p on p.id = m.user_id
  where m.group_id = p_group and m.share_steps and not p.steps_private;

  -- current periods, plus yesterday's day board (still provisional for late uploads)
  for r in
    select 'day'::text as period, b.* from public.period_bounds('day', v_today) b
    union all select 'day', b.* from public.period_bounds('day', v_today - 1) b
    union all select 'week', b.* from public.period_bounds('week', v_today) b
    union all select 'month', b.* from public.period_bounds('month', v_today) b
  loop
    delete from public.group_rankings
    where group_id = p_group and period = r.period and period_start = r.period_start;
    insert into public.group_rankings (group_id, period, period_start, user_id, steps, rank)
    select p_group, r.period, r.period_start, vt.user_id, vt.steps, rank() over (order by vt.steps desc)
    from public.visible_totals(v_users, v_tz, r.period_start, r.period_end) vt;
  end loop;

  delete from public.group_rankings
  where group_id = p_group and period_start < date_trunc('month', v_today - 1)::date - 7;
end
$$;

create or replace function public.refresh_challenge_standings(p_challenge uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c public.challenges;
  v_today date;
  v_last date;
  v_board_cut timestamptz;
begin
  select * into c from public.challenges where id = p_challenge;
  if not found or c.finalized_at is not null then return; end if;
  v_today := public.today_in(c.time_zone);
  v_last := least(coalesce(c.ends_on, v_today), v_today);
  -- Mystery challenge: nobody's current day counts towards what others see.
  v_board_cut := case when c.mystery_mode then public.day_start(v_today, c.time_zone)
                      else 'infinity'::timestamptz end;

  delete from public.challenge_standings where challenge_id = p_challenge;
  if v_last < c.starts_on then
    -- not started: list participants with zero steps
    insert into public.challenge_standings (challenge_id, user_id, steps, rank, visible)
    select p_challenge, cp.user_id, 0,
           case when m.share_steps and not p.steps_private then 1 end,
           m.share_steps and not p.steps_private
    from public.challenge_participants cp
    join public.group_members m on m.group_id = c.group_id and m.user_id = cp.user_id
    join public.profiles p on p.id = cp.user_id
    where cp.challenge_id = p_challenge;
    return;
  end if;

  insert into public.challenge_standings (challenge_id, user_id, steps, rank, visible)
  select p_challenge, f.user_id, coalesce(vt.steps, 0),
         case when f.visible then rank() over (partition by f.visible order by coalesce(vt.steps, 0) desc) end,
         f.visible
  from (
    select cp.user_id, (m.share_steps and not p.steps_private) as visible
    from public.challenge_participants cp
    join public.group_members m on m.group_id = c.group_id and m.user_id = cp.user_id
    join public.profiles p on p.id = cp.user_id
    where cp.challenge_id = p_challenge
  ) f
  left join public.visible_totals(
    array(select user_id from public.challenge_participants where challenge_id = p_challenge),
    c.time_zone, c.starts_on, v_last, v_board_cut) vt on vt.user_id = f.user_id;
end
$$;

create or replace function public.finalize_due_challenges()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select id from public.challenges
    where finalized_at is null and ends_on is not null
      and now() >= public.day_start(ends_on + 1, time_zone) + make_interval(hours => grace_hours)
  loop
    perform public.refresh_challenge_standings(r.id);
    insert into public.challenge_final_daily (challenge_id, user_id, day, steps)
    select r.id, cp.user_id, g::date, coalesce(ud.steps, 0)
    from public.challenge_participants cp
    join public.challenges c on c.id = cp.challenge_id
    cross join lateral generate_series(c.starts_on::timestamp, c.ends_on::timestamp, interval '1 day') g
    left join public.user_daily ud on ud.user_id = cp.user_id and ud.tz = c.time_zone and ud.day = g::date
    where cp.challenge_id = r.id
    on conflict do nothing;
    update public.challenges set finalized_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end
$$;

-- Called by pg_cron every minute. Also safe to call manually.
create or replace function public.refresh_dirty_boards(p_max int default 500)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  n int := 0;
begin
  for r in
    delete from public.board_dirty
    where (kind, id) in (select kind, id from public.board_dirty order by marked_at limit p_max for update skip locked)
    returning kind, id
  loop
    if r.kind = 'group' then
      perform public.refresh_group_rankings(r.id);
    else
      perform public.refresh_challenge_standings(r.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end
$$;

-- Day rollover: boards change period at midnight in their zone even without uploads,
-- and Mystery Mode reveals yesterday. Re-mark every open board once an hour.
create or replace function public.mark_all_boards_dirty()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.board_dirty (kind, id)
  select 'group', id from public.groups
  union all
  select 'challenge', id from public.challenges where finalized_at is null
  on conflict do nothing
$$;

-- ---------------------------------------------------------------------------
-- Read RPCs
-- ---------------------------------------------------------------------------
create or replace function public.get_group_leaderboard(
  p_group uuid, p_period text default 'day', p_previous boolean default false,
  p_limit int default 50, p_after_rank int default null, p_after_user uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_tz text;
  v_day date;
  v_start date;
  v_end date;
  v_rows jsonb;
  v_me jsonb;
  v_my_steps bigint;
  v_total int;
  v_computed timestamptz;
begin
  perform public.require_member(p_group);
  if p_period not in ('day', 'week', 'month') then raise exception 'invalid_period' using errcode = '22023'; end if;
  select time_zone into v_tz from public.groups where id = p_group;
  v_day := public.today_in(v_tz);
  if p_previous then
    if p_period <> 'day' then raise exception 'previous_only_for_day' using errcode = '22023'; end if;
    v_day := v_day - 1;
  end if;
  select b.period_start, b.period_end into v_start, v_end from public.period_bounds(p_period, v_day) b;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', x.user_id, 'display_name', x.display_name, 'avatar_emoji', x.avatar_emoji,
           'steps', x.steps, 'rank', x.rank, 'is_me', x.user_id = v_uid) order by x.rank, x.user_id), '[]'::jsonb),
         max(x.computed_at)
  into v_rows, v_computed
  from (
    select r.user_id, p.display_name, p.avatar_emoji, r.steps, r.rank, r.computed_at
    from public.group_rankings r join public.profiles p on p.id = r.user_id
    where r.group_id = p_group and r.period = p_period and r.period_start = v_start
      and (p_after_rank is null or (r.rank, r.user_id) > (p_after_rank, p_after_user))
      and not exists (select 1 from public.blocks b where b.blocker_id = v_uid and b.blocked_id = r.user_id)
    order by r.rank, r.user_id
    limit least(greatest(p_limit, 1), 200)
  ) x;

  select count(*) into v_total from public.group_rankings
  where group_id = p_group and period = p_period and period_start = v_start;

  -- The viewer always sees their own live total; their rank is their position on
  -- the board as others see it (null if they don't share steps with this group).
  select coalesce(sum(steps), 0) into v_my_steps from public.user_daily
  where user_id = v_uid and tz = v_tz and day between v_start and v_end;
  select jsonb_build_object('rank', r.rank, 'board_steps', r.steps) into v_me
  from public.group_rankings r
  where r.group_id = p_group and r.period = p_period and r.period_start = v_start and r.user_id = v_uid;

  return jsonb_build_object(
    'period', p_period, 'period_start', v_start, 'period_end', v_end, 'time_zone', v_tz,
    'provisional', p_previous, 'computed_at', v_computed, 'total_ranked', v_total,
    'rows', v_rows,
    'me', coalesce(v_me, '{}'::jsonb) || jsonb_build_object('live_steps', v_my_steps,
          'ranked', v_me is not null));
end
$$;

-- ---------------------------------------------------------------------------
-- Challenges
-- ---------------------------------------------------------------------------
create or replace function public.create_challenge(
  p_group uuid, p_name text, p_starts_on date, p_ends_on date default null,
  p_time_zone text default null, p_mystery_mode boolean default false,
  p_daily_target int default null, p_description text default null, p_grace_hours int default 48)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_tz text;
begin
  perform public.require_admin(p_group);
  perform public.enforce_rate_limit('create_challenge', 20, interval '1 day');
  v_tz := coalesce(p_time_zone, (select time_zone from public.groups where id = p_group));
  if public.valid_tz(v_tz) is null then raise exception 'invalid_time_zone' using errcode = '22023'; end if;
  if p_starts_on < public.today_in(v_tz) - 1 then
    raise exception 'start_in_past' using errcode = '22023';
  end if;
  insert into public.challenges (group_id, name, description, time_zone, starts_on, ends_on,
                                 mystery_mode, daily_target, grace_hours, created_by)
  values (p_group, btrim(p_name), nullif(btrim(p_description), ''), v_tz, p_starts_on, p_ends_on,
          p_mystery_mode, p_daily_target, p_grace_hours, auth.uid())
  returning id into v_id;
  perform public.join_challenge(v_id);
  return v_id;
end
$$;

create or replace function public.join_challenge(p_challenge uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c public.challenges;
  v_uid uuid := public.require_uid();
begin
  select * into c from public.challenges where id = p_challenge;
  if not found then raise exception 'challenge_not_found' using errcode = 'P0002'; end if;
  perform public.require_member(c.group_id);
  if c.finalized_at is not null or (c.ends_on is not null and c.ends_on < public.today_in(c.time_zone)) then
    raise exception 'challenge_ended' using errcode = '22023';
  end if;
  insert into public.challenge_participants (challenge_id, user_id) values (p_challenge, v_uid)
  on conflict do nothing;
  perform public.rebuild_user_daily(v_uid, c.time_zone, least(c.starts_on, current_date) - 1);
  perform public.mark_user_boards_dirty(v_uid);
end
$$;

create or replace function public.leave_challenge(p_challenge uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.mark_user_boards_dirty(public.require_uid());
  delete from public.challenge_participants where challenge_id = p_challenge and user_id = auth.uid();
end
$$;

create or replace function public.get_group_challenges(p_group uuid)
returns table (id uuid, name text, description text, time_zone text, starts_on date, ends_on date,
               mystery_mode boolean, daily_target int, finalized_at timestamptz, participant_count bigint,
               joined boolean, status text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_member(p_group);
  return query
  select c.id, c.name, c.description, c.time_zone, c.starts_on, c.ends_on, c.mystery_mode, c.daily_target,
         c.finalized_at,
         (select count(*) from public.challenge_participants x where x.challenge_id = c.id),
         exists (select 1 from public.challenge_participants x where x.challenge_id = c.id and x.user_id = auth.uid()),
         case when c.finalized_at is not null then 'final'
              when c.starts_on > public.today_in(c.time_zone) then 'upcoming'
              when c.ends_on is not null and c.ends_on < public.today_in(c.time_zone) then 'provisional'
              else 'active' end
  from public.challenges c
  where c.group_id = p_group
  order by c.finalized_at nulls first, c.starts_on desc;
end
$$;

create or replace function public.get_my_challenges()
returns table (id uuid, group_id uuid, group_name text, name text, time_zone text, starts_on date,
               ends_on date, mystery_mode boolean, finalized_at timestamptz, status text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.id, c.group_id, g.name, c.name, c.time_zone, c.starts_on, c.ends_on, c.mystery_mode, c.finalized_at,
         case when c.finalized_at is not null then 'final'
              when c.starts_on > public.today_in(c.time_zone) then 'upcoming'
              when c.ends_on is not null and c.ends_on < public.today_in(c.time_zone) then 'provisional'
              else 'active' end
  from public.challenge_participants cp
  join public.challenges c on c.id = cp.challenge_id
  join public.groups g on g.id = c.group_id
  where cp.user_id = auth.uid()
  order by c.finalized_at nulls first, c.starts_on desc
$$;

create or replace function public.get_challenge_leaderboard(
  p_challenge uuid, p_limit int default 50, p_after_rank int default null, p_after_user uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c public.challenges;
  v_uid uuid := public.require_uid();
  v_today date;
  v_last date;
  v_rows jsonb;
  v_me jsonb;
  v_my_live bigint;
  v_my_today bigint;
  v_total int;
  v_computed timestamptz;
begin
  select * into c from public.challenges where id = p_challenge;
  if not found then raise exception 'challenge_not_found' using errcode = 'P0002'; end if;
  perform public.require_member(c.group_id);
  v_today := public.today_in(c.time_zone);
  v_last := least(coalesce(c.ends_on, v_today), v_today);

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', x.user_id, 'display_name', x.display_name, 'avatar_emoji', x.avatar_emoji,
           'steps', x.steps, 'rank', x.rank, 'is_me', x.user_id = v_uid) order by x.rank, x.user_id), '[]'::jsonb),
         max(x.computed_at)
  into v_rows, v_computed
  from (
    select s.user_id, p.display_name, p.avatar_emoji, s.steps, s.rank, s.computed_at
    from public.challenge_standings s join public.profiles p on p.id = s.user_id
    where s.challenge_id = p_challenge and s.visible
      and (p_after_rank is null or (s.rank, s.user_id) > (p_after_rank, p_after_user))
      and not exists (select 1 from public.blocks b where b.blocker_id = v_uid and b.blocked_id = s.user_id)
    order by s.rank, s.user_id
    limit least(greatest(p_limit, 1), 200)
  ) x;

  select count(*) into v_total from public.challenge_standings where challenge_id = p_challenge and visible;

  select coalesce(sum(steps), 0), coalesce(sum(steps) filter (where day = v_today), 0)
  into v_my_live, v_my_today
  from public.user_daily
  where user_id = v_uid and tz = c.time_zone and day between c.starts_on and v_last;

  select jsonb_build_object('rank', s.rank, 'board_steps', s.steps, 'visible', s.visible) into v_me
  from public.challenge_standings s where s.challenge_id = p_challenge and s.user_id = v_uid;

  return jsonb_build_object(
    'challenge_id', c.id, 'name', c.name, 'time_zone', c.time_zone,
    'starts_on', c.starts_on, 'ends_on', c.ends_on, 'mystery_mode', c.mystery_mode,
    'status', case when c.finalized_at is not null then 'final'
                   when c.starts_on > v_today then 'upcoming'
                   when c.ends_on is not null and c.ends_on < v_today then 'provisional'
                   else 'active' end,
    'final_at', case when c.ends_on is not null
                     then public.day_start(c.ends_on + 1, c.time_zone) + make_interval(hours => c.grace_hours) end,
    'reveal_at', case when c.mystery_mode and c.finalized_at is null
                      then public.day_start(v_today + 1, c.time_zone) end,
    'computed_at', v_computed, 'total_ranked', v_total, 'rows', v_rows,
    'me', coalesce(v_me, '{}'::jsonb) || jsonb_build_object(
            'joined', exists (select 1 from public.challenge_participants where challenge_id = c.id and user_id = v_uid),
            'live_steps', v_my_live, 'today_steps', v_my_today));
end
$$;

-- CSV export for owners/admins. Same visibility + Mystery Mode rules as the app:
--   * participants who don't share steps with the group appear with "hidden" cells;
--   * Mystery Mode (until final): the current day in the challenge zone is omitted;
--   * a participant's own Mystery cut-off from *other* challenges also applies.
create or replace function public.csv_cell(p text)
returns text
language sql
immutable
as $$
  -- quote, escape quotes, and neutralise spreadsheet formula injection
  select '"' || replace(case when p ~ '^[=+\-@\t\r]' then '''' || p else p end, '"', '""') || '"'
$$;

create or replace function public.export_challenge_csv(p_challenge uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c public.challenges;
  v_today date;
  v_last date;
  v_header text;
  v_body text;
  v_board_cut timestamptz;
begin
  select * into c from public.challenges where id = p_challenge;
  if not found then raise exception 'challenge_not_found' using errcode = 'P0002'; end if;
  perform public.require_admin(c.group_id);
  perform public.enforce_rate_limit('export_csv', 30, interval '1 hour');

  v_today := public.today_in(c.time_zone);
  v_last := least(coalesce(c.ends_on, v_today), v_today);
  v_board_cut := case when c.mystery_mode and c.finalized_at is null
                      then public.day_start(v_today, c.time_zone) else 'infinity'::timestamptz end;
  if v_board_cut <> 'infinity'::timestamptz then
    v_last := least(v_last, v_today - 1);
  end if;

  select 'rank,participant,' ||
         coalesce(string_agg(to_char(g::date, 'YYYY-MM-DD') ||
                  case when g::date = v_today and c.finalized_at is null then ' (in progress)' else '' end,
                  ',' order by g) || ',', '') ||
         'total'
  into v_header
  from generate_series(c.starts_on::timestamp, v_last::timestamp, interval '1 day') g;

  if c.finalized_at is not null then
    -- Final results are frozen: daily cells, totals and ranks come from the snapshot
    -- taken at finalisation, so late uploads can never change an exported result.
    select string_agg(
             coalesce(s.rank::text, '') || ',' || public.csv_cell(p.display_name) || ',' ||
             coalesce((select string_agg(case when s.visible then f.steps::text else 'hidden' end, ',' order by f.day)
                       from public.challenge_final_daily f
                       where f.challenge_id = p_challenge and f.user_id = s.user_id) || ',', '') ||
             case when s.visible then s.steps::text else 'hidden' end,
             E'\n' order by s.rank nulls last, p.display_name, s.user_id)
    into v_body
    from public.challenge_standings s join public.profiles p on p.id = s.user_id
    where s.challenge_id = p_challenge;
    return v_header || E'\n' || coalesce(v_body, '') || E'\n';
  end if;

  -- Live export: re-score first so totals and ranks match the daily cells exactly.
  perform public.refresh_challenge_standings(p_challenge);

  with parts as (
    select cp.user_id, p.display_name, s.rank, s.steps as total, coalesce(s.visible, false) as visible,
           least(v_board_cut, coalesce(mc.cutoff, 'infinity'::timestamptz)) as cut
    from public.challenge_participants cp
    join public.profiles p on p.id = cp.user_id
    left join public.challenge_standings s on s.challenge_id = cp.challenge_id and s.user_id = cp.user_id
    left join public.mystery_cutoffs mc on mc.user_id = cp.user_id
    where cp.challenge_id = p_challenge
  ), pc as (
    select parts.*,
           case when cut = 'infinity'::timestamptz then null else (cut at time zone c.time_zone)::date end as cut_day
    from parts
  ), partial as (
    select pc.user_id, sum(e.steps) as s
    from pc join public.effective_hourly e
      on e.user_id = pc.user_id
     and e.bucket_start >= (pc.cut_day::timestamp at time zone c.time_zone)
     and e.bucket_start < pc.cut
    where pc.visible and pc.cut_day between c.starts_on and v_last
    group by pc.user_id
  ), days as (
    select g::date as d from generate_series(c.starts_on::timestamp, v_last::timestamp, interval '1 day') g
  ), cells as (
    select pc.user_id,
           string_agg(
             case when not pc.visible then 'hidden'
                  when pc.cut_day is null or days.d < pc.cut_day then coalesce(ud.steps, 0)::text
                  when days.d = pc.cut_day then coalesce(pt.s, 0)::text
                  else 'hidden' end, ',' order by days.d) as line
    from pc cross join days
    left join public.user_daily ud on ud.user_id = pc.user_id and ud.tz = c.time_zone and ud.day = days.d
    left join partial pt on pt.user_id = pc.user_id
    group by pc.user_id
  )
  select string_agg(
           coalesce(pc.rank::text, '') || ',' || public.csv_cell(pc.display_name) || ',' ||
           coalesce(ce.line || ',', '') ||
           case when pc.visible then coalesce(pc.total, 0)::text else 'hidden' end,
           E'\n' order by pc.rank nulls last, pc.display_name, pc.user_id)
  into v_body
  from pc left join cells ce on ce.user_id = pc.user_id;

  return v_header || E'\n' || coalesce(v_body, '') || E'\n';
end
$$;
