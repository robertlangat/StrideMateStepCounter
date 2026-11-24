-- Sync idempotency, source de-duplication, midnight rollover / time zones,
-- validation, implausible activity and rate limits.
set timezone = 'UTC';

-- 1. Retried uploads cannot inflate totals ---------------------------------
do $$
declare
  u uuid := t.new_user('Idem');
  b uuid := gen_random_uuid();
  h timestamptz := t.hour0();
  payload jsonb := jsonb_build_array(jsonb_build_object('source_id','phone:android','source_kind','phone','bucket_start',h,'steps',1500));
  r jsonb;
begin
  perform t.login(u);
  r := public.upload_step_buckets(b, payload);
  perform t.eq((r->>'duplicate')::boolean, false, 'first upload not duplicate');
  r := public.upload_step_buckets(b, payload);            -- network retry, same batch id
  perform t.eq((r->>'duplicate')::boolean, true, 'replayed batch flagged duplicate');
  r := public.upload_step_buckets(gen_random_uuid(), payload); -- same data, new batch id
  perform t.logout();
  perform t.eq(t.daily(u, 'UTC', h::date), 1500, 'replays do not inflate');
  perform t.up(u, 'phone:android', 'phone', h, 1200);      -- stale, lower cumulative value
  perform t.eq(t.daily(u, 'UTC', h::date), 1500, 'lower late value ignored (max-merge)');
  perform t.up(u, 'phone:android', 'phone', h, 1800);      -- hour still in progress
  perform t.eq(t.daily(u, 'UTC', h::date), 1800, 'higher value advances');
  -- duplicates inside one batch collapse
  perform t.login(u);
  r := public.upload_step_buckets(gen_random_uuid(), jsonb_build_array(
        jsonb_build_object('source_id','phone:android','source_kind','phone','bucket_start',h,'steps',1900),
        jsonb_build_object('source_id','phone:android','source_kind','phone','bucket_start',h,'steps',1850)));
  perform t.logout();
  perform t.eq(t.daily(u, 'UTC', h::date), 1900, 'in-batch duplicates collapse to max');
  raise notice 'PASS sync idempotency';
end $$;

-- 2. Overlapping phone + wearable data are not double counted ----------------
do $$
declare
  u uuid := t.new_user('Dedup');
  d date := (t.today0() - interval '1 day')::date;
  h1 timestamptz := t.today0() - interval '20 hours';
  h2 timestamptz := t.today0() - interval '19 hours';
begin
  perform t.up(u, 'phone:android', 'phone', h1, 1000);
  perform t.up(u, 'health:connect', 'health', h1, 1200);   -- same walk seen by watch + phone
  perform t.up(u, 'phone:android', 'phone', h2, 0);
  perform t.up(u, 'health:connect', 'health', h2, 700);    -- phone left on desk
  perform t.eq(t.daily(u, 'UTC', d), 1900, 'auto = per-hour max, never a sum');
  update public.profiles set source_policy = 'prefer_phone' where id = u;
  perform t.eq(t.daily(u, 'UTC', d), 1700, 'prefer_phone uses phone when it has steps, else falls back');
  update public.profiles set source_policy = 'prefer_health' where id = u;
  perform t.eq(t.daily(u, 'UTC', d), 1900, 'prefer_health');
  raise notice 'PASS source de-duplication';
end $$;

-- 3. Midnight rollover and time zones ---------------------------------------
do $$
declare
  u uuid := t.new_user('Nairobi', 'Africa/Nairobi');
  k uuid := t.new_user('Kolkata', 'Asia/Kolkata');
  base date := (t.today0() - interval '3 days')::date;
  h_2100 timestamptz := base::timestamp + interval '21 hours';  -- 21:00 UTC = 00:00 EAT next day
  h_2000 timestamptz := base::timestamp + interval '20 hours';  -- 20:00 UTC = 23:00 EAT
begin
  perform t.up(u, 'phone:android', 'phone', h_2000, 400);
  perform t.up(u, 'phone:android', 'phone', h_2100, 600);
  perform t.eq(t.daily(u, 'Africa/Nairobi', base), 400, 'EAT 23:00 bucket stays on day D');
  perform t.eq(t.daily(u, 'Africa/Nairobi', base + 1), 600, 'EAT 00:00 bucket rolls to D+1');
  -- Join a UTC group: totals are materialised in the group zone too
  perform t.login(u);
  perform public.create_group('UTC walkers', null, 'UTC');
  perform t.logout();
  perform t.eq(t.daily(u, 'UTC', base), 1000, 'same buckets, UTC day boundary');
  -- User travels: own zone changes, history is rebuilt in the new zone
  update public.profiles set time_zone = 'America/New_York' where id = u;
  perform t.eq(t.daily(u, 'America/New_York', base), 1000, '15:00-17:00 EST same day');
  -- Half-hour offset zone: 18:00 UTC = 23:30 IST; the hour bucket is attributed by its start
  perform t.up(k, 'phone:android', 'phone', base::timestamp + interval '18 hours', 300);
  perform t.up(k, 'phone:android', 'phone', base::timestamp + interval '19 hours', 200);
  perform t.eq(t.daily(k, 'Asia/Kolkata', base), 300, 'IST 23:30 bucket on day D');
  perform t.eq(t.daily(k, 'Asia/Kolkata', base + 1), 200, 'IST 00:30 bucket on D+1');
  raise notice 'PASS midnight rollover / time zones';
end $$;

-- 4. Validation and implausible activity -------------------------------------
do $$
declare
  u uuid := t.new_user('Validator');
  r jsonb;
begin
  perform t.login(u);
  r := public.upload_step_buckets(gen_random_uuid(), jsonb_build_array(
    jsonb_build_object('source_id','phone:android','source_kind','phone','bucket_start', t.hour0() + interval '15 minutes','steps',10),
    jsonb_build_object('source_id','phone:android','source_kind','phone','bucket_start', t.hour0() + interval '5 hours','steps',10),
    jsonb_build_object('source_id','phone:android','source_kind','robot','bucket_start', t.hour0(),'steps',10),
    jsonb_build_object('source_id','phone:android','source_kind','phone','bucket_start', t.hour0() - interval '1 hour','steps',40000)));
  perform t.logout();
  perform t.eq((r->>'rejected')::int, 3, 'misaligned, future and unknown-kind buckets rejected');
  perform t.eq((r->>'clamped')::int, 1, 'implausible hour clamped');
  perform t.ok((select flagged_at is not null from public.profiles where id = u), 'implausible activity flags the account');
  perform t.raises($q$ select public.upload_step_buckets(gen_random_uuid(), '[]') $q$, 'not_authenticated', 'anonymous upload refused');
  raise notice 'PASS validation / implausible activity';
end $$;

-- 5. Rate limit on step uploads -----------------------------------------------
do $$
declare
  u uuid := t.new_user('Spammer');
  i int;
begin
  perform t.login(u);
  for i in 1..240 loop
    perform public.upload_step_buckets(gen_random_uuid(), '[]'::jsonb);
  end loop;
  perform t.raises($q$ select public.upload_step_buckets(gen_random_uuid(), '[]'::jsonb) $q$, 'rate_limited', '241st upload in an hour refused');
  perform t.logout();
  raise notice 'PASS upload rate limit';
end $$;

-- 6. Rest days -----------------------------------------------------------------
do $$
declare
  u uuid := t.new_user('Rester');
  monday date := date_trunc('week', current_date + 7)::date;
begin
  perform t.login(u);
  perform t.raises($q$ select public.set_rest_day(current_date - 1, true) $q$, 'rest_day_in_past', 'no retroactive rest days');
  perform public.set_rest_day(monday, true);
  perform public.set_rest_day(monday + 1, true);
  perform t.raises(format('select public.set_rest_day(%L, true)', monday + 2), 'rest_day_week_limit', 'max 2 rest days per week');
  perform public.set_rest_day(monday + 1, false);
  perform public.set_rest_day(monday + 2, true);
  perform t.logout();
  perform t.eq((select count(*)::int from public.rest_days where user_id = u), 2, 'rest day toggling');
  raise notice 'PASS rest days';
end $$;
