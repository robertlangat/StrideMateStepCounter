-- Load test: one private group with 15,000 synthetic members, 31 days of history,
-- plus a 15,000-participant Mystery Mode challenge. Each step runs in its own
-- transaction (as the pg_cron jobs and API calls do in production) after VACUUM
-- ANALYZE. Prints timings and fails if interactive paths exceed their budgets.
-- Run with: scripts/test_db.sh --load
set timezone = 'UTC';
create table t.load_ctx (g uuid, ch uuid, owner uuid, probe uuid);

-- 1. Synthetic data ---------------------------------------------------------------
do $$
declare
  n constant int := 15000;
  g uuid; owner uuid; t0 timestamptz := clock_timestamp();
begin
  insert into auth.users (email, raw_user_meta_data)
  select 'load' || k || '@example.test', jsonb_build_object('display_name', 'Walker ' || k)
  from generate_series(1, n) k;
  select id into owner from auth.users where email = 'load1@example.test';
  insert into public.groups (name, owner_id, time_zone) values ('Load test club', owner, 'Africa/Nairobi') returning id into g;
  insert into public.group_members (group_id, user_id, role)
  select g, u.id, case when u.id = owner then 'owner'::public.group_role else 'member' end
  from auth.users u where u.email like 'load%@example.test';
  insert into public.user_daily (user_id, tz, day, steps)
  select m.user_id, 'Africa/Nairobi', d::date, (2000 + floor(random() * 14000))::int
  from public.group_members m
  cross join generate_series(public.today_in('Africa/Nairobi') - 30, public.today_in('Africa/Nairobi'), interval '1 day') d
  where m.group_id = g;
  insert into public.effective_hourly (user_id, bucket_start, steps)
  select m.user_id, h, (floor(random() * 900))::int
  from public.group_members m
  cross join generate_series(date_trunc('hour', now()) - interval '36 hours', date_trunc('hour', now()), interval '1 hour') h
  where m.group_id = g;
  insert into t.load_ctx (g, owner) values (g, owner);
  raise notice 'LOAD setup: % members, % daily rows, % hourly rows in % s', n,
    (select count(*) from public.user_daily), (select count(*) from public.effective_hourly),
    round(extract(epoch from clock_timestamp() - t0)::numeric, 1);
end $$;
vacuum analyze;

-- 2. Server-maintained ranking refresh (what pg_cron runs each minute for a dirty group)
do $$
declare c t.load_ctx; t0 timestamptz := clock_timestamp();
begin
  select * into c from t.load_ctx;
  perform public.refresh_group_rankings(c.g);
  raise notice 'LOAD refresh_group_rankings (4 boards: today, yesterday, week, month x 15k members): % ms',
    round(extract(epoch from clock_timestamp() - t0)::numeric * 1000);
  perform t.eq((select count(*)::int from public.group_rankings where group_id = c.g and period = 'month'), 15000, 'all members ranked');
  update t.load_ctx set probe = (select user_id from public.group_rankings
    where group_id = c.g and period = 'day' and period_start = public.today_in('Africa/Nairobi')
    order by rank desc limit 1);
end $$;
vacuum analyze public.group_rankings;

-- 3. Interactive reads + uploads as a member ranked near the bottom -----------------
do $$
declare c t.load_ctx; t0 timestamptz; ms numeric; i int; lb jsonb; budget constant numeric := 50;
begin
  select * into c from t.load_ctx;
  perform t.login(c.probe);
  t0 := clock_timestamp();
  for i in 1..20 loop lb := public.get_group_leaderboard(c.g, 'day', false, 50); end loop;
  ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / 20, 2);
  raise notice 'LOAD get_group_leaderboard first page (50 rows + own rank): % ms avg', ms;
  perform t.ok(ms < budget, 'first page within budget');
  perform t.ok((lb->'me'->>'rank')::int > 14000, 'own rank returned from far outside the page');
  t0 := clock_timestamp();
  for i in 1..20 loop lb := public.get_group_leaderboard(c.g, 'month', false, 50, 7000, null); end loop;
  ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / 20, 2);
  raise notice 'LOAD get_group_leaderboard deep keyset page (rank > 7000, month): % ms avg', ms;
  perform t.ok(ms < budget, 'deep page within budget');
  perform t.ok((lb->'rows'->0->>'rank')::int > 7000, 'keyset page starts after cursor');
  t0 := clock_timestamp();
  for i in 1..20 loop perform * from public.get_group_members(c.g, 50, now() - interval '1 day', null); end loop;
  ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / 20, 2);
  raise notice 'LOAD get_group_members page: % ms avg', ms;
  perform t.ok(ms < budget, 'member page within budget');
  t0 := clock_timestamp();
  for i in 1..20 loop
    perform public.upload_step_buckets(gen_random_uuid(), jsonb_build_array(jsonb_build_object(
      'source_id', 'phone:android', 'source_kind', 'phone', 'bucket_start', date_trunc('hour', now()), 'steps', 100 + i)));
  end loop;
  ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / 20, 2);
  raise notice 'LOAD upload_step_buckets by a member of the 15k group: % ms avg', ms;
  perform t.ok(ms < 250, 'upload within budget');
  perform t.logout();
end $$;

-- 4. Mystery Mode challenge with every member: worst case for visibility cut-offs ----
do $$
declare c t.load_ctx; v_ch uuid;
begin
  select * into c from t.load_ctx;
  insert into public.challenges (group_id, name, time_zone, starts_on, ends_on, mystery_mode, created_by)
  values (c.g, 'Load mystery', 'Africa/Nairobi', public.today_in('Africa/Nairobi') - 29, null, true, c.owner)
  returning id into v_ch;
  insert into public.challenge_participants (challenge_id, user_id)
  select v_ch, user_id from public.group_members where group_id = c.g;
  update public.group_members set role = 'admin' where group_id = c.g and user_id = c.probe;
  update t.load_ctx set ch = v_ch;
end $$;
vacuum analyze;

do $$
declare c t.load_ctx; t0 timestamptz := clock_timestamp();
begin
  select * into c from t.load_ctx;
  perform public.refresh_challenge_standings(c.ch);
  raise notice 'LOAD refresh_challenge_standings (15k participants, 30 days, Mystery Mode): % ms',
    round(extract(epoch from clock_timestamp() - t0)::numeric * 1000);
end $$;

do $$
declare c t.load_ctx; t0 timestamptz := clock_timestamp();
begin
  select * into c from t.load_ctx;
  perform public.refresh_group_rankings(c.g);
  raise notice 'LOAD refresh_group_rankings with all 15k members in Mystery Mode (hourly cut-offs): % ms',
    round(extract(epoch from clock_timestamp() - t0)::numeric * 1000);
end $$;
vacuum analyze public.challenge_standings, public.group_rankings;

do $$
declare c t.load_ctx; t0 timestamptz; ms numeric; i int; lb jsonb; csv text;
begin
  select * into c from t.load_ctx;
  perform t.login(c.probe);
  t0 := clock_timestamp();
  for i in 1..20 loop lb := public.get_challenge_leaderboard(c.ch, 50); end loop;
  ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / 20, 2);
  raise notice 'LOAD get_challenge_leaderboard (Mystery, own rank): % ms avg', ms;
  perform t.ok(ms < 50, 'challenge page within budget');
  perform t.ok((lb->'me'->>'live_steps')::bigint > (lb->'me'->>'board_steps')::bigint, 'own live total > revealed total');
  t0 := clock_timestamp();
  csv := public.export_challenge_csv(c.ch);
  raise notice 'LOAD export_challenge_csv: % rows x % day columns, % KB in % ms (includes re-scoring)',
    array_length(string_to_array(csv, E'\n'), 1) - 2,
    array_length(string_to_array(split_part(csv, E'\n', 1), ','), 1) - 3,
    round(octet_length(csv) / 1024.0),
    round(extract(epoch from clock_timestamp() - t0)::numeric * 1000);
  perform t.logout();
  perform t.eq(array_length(string_to_array(csv, E'\n'), 1) - 2, 15000, 'CSV has one row per participant');
  perform t.ok(split_part(csv, E'\n', 1) not like '%' || to_char(public.today_in('Africa/Nairobi'), 'YYYY-MM-DD') || '%',
               'Mystery CSV omits current day');
end $$;

do $$
declare t0 timestamptz := clock_timestamp(); n int;
begin
  perform public.mark_all_boards_dirty();
  n := public.refresh_dirty_boards();
  raise notice 'LOAD refresh_dirty_boards (all boards incl. 15k group + 15k challenge): % boards in % ms', n,
    round(extract(epoch from clock_timestamp() - t0)::numeric * 1000);
  raise notice 'PASS large-group load test (15,000 members)';
end $$;

-- Confirm the page query is an index range scan, not a sort of the whole group.
explain (costs off)
select r.user_id, r.rank from public.group_rankings r
where r.group_id = (select g from t.load_ctx)
  and r.period = 'day' and r.period_start = public.today_in('Africa/Nairobi')
  and (r.rank, r.user_id) > (7000, '00000000-0000-0000-0000-000000000000'::uuid)
order by r.rank, r.user_id limit 50;
