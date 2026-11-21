-- Opt-in country/global rankings, daily challenge result notices, personal data
-- export, account deletion, scheduled jobs, realtime publication and grants.

-- ---------------------------------------------------------------------------
-- Global / country rankings (opt-in, real people only - bots never reach the server)
-- Board for local date D = every opted-in user's own local day D.
-- ---------------------------------------------------------------------------
create table public.global_rankings (
  scope text not null,                 -- 'GLOBAL' or ISO-3166 alpha-2 country code
  period text not null check (period in ('day', 'week', 'month')),
  period_start date not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  steps bigint not null,
  rank int not null,
  computed_at timestamptz not null default now(),
  primary key (scope, period, period_start, user_id)
);
create index global_rankings_page on public.global_rankings (scope, period, period_start, rank, user_id);
alter table public.global_rankings enable row level security; -- RPC only

create or replace function public.refresh_global_rankings()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  for r in
    select 'day'::text as period, b.* from public.period_bounds('day', current_date - 1) b
    union all select 'day', b.* from public.period_bounds('day', current_date) b
    union all select 'day', b.* from public.period_bounds('day', current_date + 1) b
    union all select 'week', b.* from public.period_bounds('week', current_date) b
    union all select 'month', b.* from public.period_bounds('month', current_date) b
  loop
    delete from public.global_rankings where period = r.period and period_start = r.period_start;

    if to_regclass('pg_temp._gt') is null then
      create temp table _gt (user_id uuid, country text, steps bigint) on commit drop;
    end if;
    truncate _gt;
    insert into _gt
    select p.id, p.country_code,
           case when mc.cutoff is null then coalesce((
                  select sum(ud.steps) from public.user_daily ud
                  where ud.user_id = p.id and ud.tz = p.time_zone and ud.day between r.period_start and r.period_end), 0)
                else public.visible_steps(p.id, p.time_zone, r.period_start, r.period_end, mc.cutoff) end
    from public.profiles p
    left join public.mystery_cutoffs mc on mc.user_id = p.id
    where p.global_rankings_opt_in and not p.steps_private and p.flagged_at is null;

    insert into public.global_rankings (scope, period, period_start, user_id, steps, rank)
    select 'GLOBAL', r.period, r.period_start, user_id, steps, rank() over (order by steps desc)
    from _gt where steps > 0;

    insert into public.global_rankings (scope, period, period_start, user_id, steps, rank)
    select country, r.period, r.period_start, user_id, steps,
           rank() over (partition by country order by steps desc)
    from _gt where steps > 0 and country is not null;
  end loop;
  delete from public.global_rankings where period_start < current_date - 40;
end
$$;

create or replace function public.get_global_leaderboard(
  p_scope text, p_period text, p_date date, p_limit int default 50,
  p_after_rank int default null, p_after_user uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_start date;
  v_rows jsonb;
  v_me jsonb;
  v_total int;
begin
  if p_period not in ('day', 'week', 'month') then raise exception 'invalid_period' using errcode = '22023'; end if;
  if p_scope <> 'GLOBAL' and p_scope !~ '^[A-Z]{2}$' then raise exception 'invalid_scope' using errcode = '22023'; end if;
  select b.period_start into v_start from public.period_bounds(p_period, p_date) b;

  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', x.user_id, 'display_name', x.display_name, 'avatar_emoji', x.avatar_emoji,
      'country_code', x.country_code, 'steps', x.steps, 'rank', x.rank, 'is_me', x.user_id = v_uid)
      order by x.rank, x.user_id), '[]'::jsonb)
  into v_rows
  from (
    select g.user_id, p.display_name, p.avatar_emoji, p.country_code, g.steps, g.rank
    from public.global_rankings g join public.profiles p on p.id = g.user_id
    where g.scope = p_scope and g.period = p_period and g.period_start = v_start
      and (p_after_rank is null or (g.rank, g.user_id) > (p_after_rank, p_after_user))
      and not exists (select 1 from public.blocks b where b.blocker_id = v_uid and b.blocked_id = g.user_id)
    order by g.rank, g.user_id
    limit least(greatest(p_limit, 1), 200)
  ) x;
  select count(*) into v_total from public.global_rankings
  where scope = p_scope and period = p_period and period_start = v_start;
  select jsonb_build_object('rank', g.rank, 'steps', g.steps) into v_me
  from public.global_rankings g
  where g.scope = p_scope and g.period = p_period and g.period_start = v_start and g.user_id = v_uid;
  return jsonb_build_object('scope', p_scope, 'period', p_period, 'period_start', v_start,
    'total_ranked', v_total, 'rows', v_rows, 'me', coalesce(v_me, '{}'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------
-- Daily challenge notices: once per challenge day, after the day closes in the
-- challenge zone, tell each participant their rank. Uses the same visible
-- standings as the board, so Mystery Mode is never leaked by a notification.
-- ---------------------------------------------------------------------------
create or replace function public.send_challenge_day_notices()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c record;
  n int := 0;
  v_yday date;
begin
  for c in select * from public.challenges where finalized_at is null loop
    v_yday := public.today_in(c.time_zone) - 1;
    continue when v_yday < c.starts_on or (c.ends_on is not null and v_yday > c.ends_on);
    continue when c.last_notice_day is not null and c.last_notice_day >= v_yday;
    perform public.refresh_challenge_standings(c.id);
    insert into public.notifications (user_id, kind, title, body, data)
    select s.user_id, 'challenge_day',
           c.name || ': results for ' || to_char(v_yday, 'Mon DD'),
           case when s.rank is null then 'Your steps are hidden from this group, so you are not ranked.'
                else 'You are #' || s.rank || ' of ' ||
                     (select count(*) from public.challenge_standings z where z.challenge_id = c.id and z.visible) ||
                     ' with ' || to_char(s.steps, 'FM999,999,999') || ' steps.' end,
           jsonb_build_object('challenge_id', c.id, 'day', v_yday)
    from public.challenge_standings s where s.challenge_id = c.id;
    update public.challenges set last_notice_day = v_yday where id = c.id;
    n := n + 1;
  end loop;
  return n;
end
$$;

-- ---------------------------------------------------------------------------
-- Personal data export + account deletion
-- ---------------------------------------------------------------------------
create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
begin
  perform public.enforce_rate_limit('export_my_data', 10, interval '1 day');
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) - 'flagged_at' - 'flag_reason' from public.profiles p where id = v_uid),
    'hourly_by_source', coalesce((select jsonb_agg(jsonb_build_object('source_id', source_id, 'source_kind', source_kind,
        'bucket_start', bucket_start, 'steps', steps) order by bucket_start)
        from public.step_buckets where user_id = v_uid), '[]'),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('tz', tz, 'day', day, 'steps', steps) order by tz, day)
        from public.user_daily where user_id = v_uid), '[]'),
    'rest_days', coalesce((select jsonb_agg(day order by day) from public.rest_days where user_id = v_uid), '[]'),
    'goal_history', coalesce((select jsonb_agg(jsonb_build_object('from', effective_from, 'goal', goal))
        from public.goal_history where user_id = v_uid), '[]'),
    'achievements', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'unlocked_on', unlocked_on))
        from public.user_achievements where user_id = v_uid), '[]'),
    'groups', coalesce((select jsonb_agg(jsonb_build_object('group', g.name, 'role', m.role, 'joined_at', m.joined_at,
        'share_steps', m.share_steps)) from public.group_members m join public.groups g on g.id = m.group_id
        where m.user_id = v_uid), '[]'),
    'challenges', coalesce((select jsonb_agg(jsonb_build_object('challenge', c.name, 'joined_at', cp.joined_at))
        from public.challenge_participants cp join public.challenges c on c.id = cp.challenge_id
        where cp.user_id = v_uid), '[]'),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('group_id', group_id, 'kind', kind, 'body', body,
        'created_at', created_at) order by id) from public.messages where user_id = v_uid and deleted_at is null), '[]'),
    'blocks', coalesce((select jsonb_agg(blocked_id) from public.blocks where blocker_id = v_uid), '[]')
  );
end
$$;

-- Deletes the auth user; every user-owned row cascades. Owned groups are handed
-- to the longest-standing admin (or member); empty groups are removed.
-- Authored chat messages are deleted (not just anonymised).
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  r record;
  v_next uuid;
begin
  for r in select group_id from public.group_members where user_id = v_uid and role = 'owner' loop
    select user_id into v_next from public.group_members
    where group_id = r.group_id and user_id <> v_uid
    order by (role = 'admin') desc, joined_at, user_id limit 1;
    if v_next is null then
      delete from public.groups where id = r.group_id;
    else
      update public.group_members set role = 'member' where group_id = r.group_id and user_id = v_uid;
      update public.group_members set role = 'owner' where group_id = r.group_id and user_id = v_next;
      update public.groups set owner_id = v_next where id = r.group_id;
    end if;
  end loop;
  delete from public.messages where user_id = v_uid;
  delete from public.reports where reporter_id = v_uid;
  delete from public.rate_events where user_id = v_uid;
  delete from auth.users where id = v_uid;
end
$$;

-- ---------------------------------------------------------------------------
-- Scheduled jobs (pg_cron is available on Supabase; skipped where absent)
-- ---------------------------------------------------------------------------
create or replace function public.run_minutely_jobs()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.finalize_due_challenges();
  perform public.refresh_dirty_boards(500);
end
$$;

create or replace function public.run_hourly_jobs()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.mark_all_boards_dirty();
  perform public.refresh_global_rankings();
  perform public.send_challenge_day_notices();
  perform public.prune_rate_events();
end
$$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('stridemate-minutely', '* * * * *', 'select public.run_minutely_jobs()');
    perform cron.schedule('stridemate-hourly', '5 * * * *', 'select public.run_hourly_jobs()');
  else
    raise notice 'pg_cron not available: call run_minutely_jobs()/run_hourly_jobs() from a scheduler';
  end if;
end
$$;

-- Realtime: chat and own notifications only. Leaderboards/standings are never
-- published, so Mystery Mode cannot leak through realtime.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.messages, public.notifications;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants: least privilege. Tables are read through RLS; writes go through RPCs.
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant select on public.profiles, public.step_buckets, public.effective_hourly, public.user_daily,
  public.rest_days, public.goal_history, public.user_achievements, public.groups, public.group_members,
  public.group_invites, public.preset_messages, public.messages, public.blocks, public.notifications,
  public.challenges, public.challenge_participants
  to authenticated;
grant update (display_name, avatar_emoji, country_code, global_rankings_opt_in, steps_private,
              time_zone, daily_goal, source_policy) on public.profiles to authenticated;
grant insert on public.user_achievements to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- Helpers referenced inside policies / invoker triggers must be executable.
grant execute on function public.is_group_member(uuid), public.is_group_admin(uuid),
  public.valid_tz(text), public.today_in(text), public.day_start(date, text),
  public.period_bounds(text, date), public.csv_cell(text) to authenticated;

grant execute on function
  public.upload_step_buckets(uuid, jsonb),
  public.get_my_daily(date, date),
  public.get_my_hourly(timestamptz, timestamptz),
  public.set_rest_day(date, boolean),
  public.create_group(text, text, text),
  public.update_group_settings(uuid, text, text, boolean, boolean),
  public.get_my_groups(),
  public.create_invite(uuid, int, int),
  public.revoke_invite(text),
  public.join_group_with_code(text),
  public.set_membership_prefs(uuid, boolean, boolean),
  public.get_group_members(uuid, int, timestamptz, uuid, text),
  public.set_member_role(uuid, uuid, public.group_role),
  public.remove_member(uuid, uuid),
  public.leave_group(uuid),
  public.send_message(uuid, text, text, uuid),
  public.get_messages(uuid, bigint, int),
  public.delete_message(bigint),
  public.mute_member(uuid, uuid, int),
  public.block_user(uuid, boolean),
  public.report_content(uuid, bigint, uuid, text),
  public.list_reports(uuid, text),
  public.resolve_report(bigint, text),
  public.get_group_leaderboard(uuid, text, boolean, int, int, uuid),
  public.create_challenge(uuid, text, date, date, text, boolean, int, text, int),
  public.join_challenge(uuid),
  public.leave_challenge(uuid),
  public.get_group_challenges(uuid),
  public.get_my_challenges(),
  public.get_challenge_leaderboard(uuid, int, int, uuid),
  public.export_challenge_csv(uuid),
  public.get_global_leaderboard(text, text, date, int, int, uuid),
  public.export_my_data(),
  public.delete_my_account()
to authenticated;
