-- Challenges, Mystery Mode enforcement (API, boards, global, notifications,
-- CSV, realtime), CSV export rules, late uploads and finality.
set timezone = 'UTC';

do $$
declare
  o uuid := t.new_user('Coach'); a uuid := t.new_user('Amara'); b uuid := t.new_user('Bilal'); c uuid := t.new_user('Chen');
  g uuid; code text; m uuid; nm uuid; lb jsonb; csv text; hdr text;
  yday timestamptz := t.today0() - interval '12 hours';
  now_h timestamptz := t.hour0();
  same_week boolean := date_trunc('week', current_date) <= current_date - 1;
begin
  perform t.login(o);
  g := public.create_group('Mystery club', null, 'UTC');
  select x.code into code from public.create_invite(g, 24, null) x;
  perform t.login(a); perform public.join_group_with_code(code);
  perform t.login(b); perform public.join_group_with_code(code);
  perform t.login(c); perform public.join_group_with_code(code);
  perform t.login(o);
  m := public.create_challenge(g, 'November Mystery', current_date - 1, null, 'UTC', true);
  nm := public.create_challenge(g, 'Open race', current_date - 1, null, 'UTC', false);
  perform t.login(a); perform public.join_challenge(m); perform public.join_challenge(nm);
  perform t.login(b); perform public.join_challenge(m);
  perform t.login(c); perform public.join_challenge(nm);
  perform t.logout();
  update public.profiles set global_rankings_opt_in = true, country_code = 'KE' where id in (a, b, c);

  perform t.up(a, 'p', 'phone', yday, 3000);
  perform t.up(a, 'p', 'phone', now_h, 4111);
  perform t.up(b, 'p', 'phone', yday, 2000);
  perform t.up(b, 'p', 'phone', now_h, 5000);
  perform t.up(c, 'p', 'phone', now_h, 6000);
  perform public.refresh_dirty_boards();

  -- Challenge board (API): others see only completed days
  perform t.login(b);
  lb := public.get_challenge_leaderboard(m);
  perform t.eq((lb->>'mystery_mode')::boolean, true, 'mystery flag returned');
  perform t.eq((lb->'rows'->0->>'user_id')::uuid, a, 'ranked on yesterday only: Amara leads');
  perform t.eq((lb->'rows'->0->>'steps')::int, 3000, 'Amara today hidden from Bilal');
  perform t.eq((lb->'me'->>'live_steps')::int, 7000, 'Bilal sees own live total');
  perform t.eq((lb->'me'->>'today_steps')::int, 5000, 'Bilal sees own today');
  perform t.eq((lb->'me'->>'board_steps')::int, 2000, 'Bilal board total excludes today');
  perform t.eq((lb->'me'->>'rank')::int, 2, 'Bilal rank uses revealed data only');
  perform t.ok(lb->>'reveal_at' is not null, 'reveal time provided');
  perform t.ok(lb::text not like '%7111%' and lb::text not like '%4111%', 'no hidden value anywhere in payload');

  -- Same participants on other boards: no leak through group, other challenges, global
  lb := public.get_group_leaderboard(g, 'day');
  perform t.eq((select (r->>'steps')::int from jsonb_array_elements(lb->'rows') r where (r->>'user_id')::uuid = a), 0,
               'group day board hides mystery participant today');
  perform t.eq((select (r->>'steps')::int from jsonb_array_elements(lb->'rows') r where (r->>'user_id')::uuid = c), 6000,
               'non-mystery member shown live');
  lb := public.get_group_leaderboard(g, 'week');
  perform t.eq((select (r->>'steps')::int from jsonb_array_elements(lb->'rows') r where (r->>'user_id')::uuid = a),
               case when same_week then 3000 else 0 end, 'group week board counts mystery user through yesterday');
  lb := public.get_group_leaderboard(g, 'day', true);
  perform t.eq((select (r->>'steps')::int from jsonb_array_elements(lb->'rows') r where (r->>'user_id')::uuid = a), 3000,
               'yesterday revealed on day board');
  lb := public.get_challenge_leaderboard(nm);
  perform t.eq((select (r->>'steps')::int from jsonb_array_elements(lb->'rows') r where (r->>'user_id')::uuid = a), 3000,
               'non-mystery challenge cannot leak a mystery participant today');
  perform t.eq((select (r->>'steps')::int from jsonb_array_elements(lb->'rows') r where (r->>'user_id')::uuid = c), 6000,
               'non-mystery challenge live for others');
  perform t.logout();
  perform public.refresh_global_rankings();
  perform t.login(b);
  lb := public.get_global_leaderboard('KE', 'day', current_date);
  perform t.ok(lb::text not like '%' || a::text || '%', 'global day board omits mystery participant today');
  lb := public.get_global_leaderboard('KE', 'day', current_date - 1);
  perform t.eq((select (r->>'steps')::int from jsonb_array_elements(lb->'rows') r where (r->>'user_id')::uuid = a), 3000,
               'global board shows revealed day');

  -- CSV: admin only; today's column omitted; same totals and ranks as the app
  perform t.raises(format('select public.export_challenge_csv(%L)', m), 'admin_required', 'members cannot export');
  perform t.login(o);
  update public.profiles set display_name = 'Hacked' where id = b;      -- RLS: cannot edit others
  perform t.logout();
  perform t.eq((select display_name from public.profiles where id = b), 'Bilal', 'cannot rename another user');
  update public.profiles set display_name = '=HYPERLINK("x")' where id = b;
  perform t.login(o);
  csv := public.export_challenge_csv(m);
  hdr := split_part(csv, E'\n', 1);
  perform t.eq(hdr, 'rank,participant,' || to_char(current_date - 1, 'YYYY-MM-DD') || ',total', 'CSV header omits current day');
  perform t.ok(csv like '%1,"Amara",3000,3000%', 'CSV row for leader with revealed totals');
  perform t.ok(csv like '%2,"''=HYPERLINK(""x"")",2000,2000%', 'CSV escapes quotes and neutralises formulas');
  perform t.ok(csv not like '%7111%' and csv not like '%4111%' and csv not like '%,5000%', 'no current-day values in CSV');
  csv := public.export_challenge_csv(nm);
  perform t.ok(split_part(csv, E'\n', 1) like '%(in progress),total', 'non-mystery CSV includes live day, labelled');
  perform t.ok(csv like '%"Chen",0,6000,6000%', 'non-mystery live values for Chen');
  perform t.ok(csv like '%"Amara",3000,0,3000%', 'Amara mystery cut-off also applies in other challenge export');

  -- Notifications use revealed standings only
  perform t.logout();
  perform public.send_challenge_day_notices();
  perform t.ok(exists (select 1 from public.notifications where user_id = a and kind = 'challenge_day'
                      and data->>'challenge_id' = m::text and body like '%#1 of 3 with 3,000 steps%'), 'notice uses revealed totals');
  perform t.ok(not exists (select 1 from public.notifications where body like '%7,111%' or body like '%7,000%'), 'no notice leaks today');
  perform t.eq(public.send_challenge_day_notices(), 0, 'notices sent once per day');

  -- Realtime publication carries chat + own notifications only
  perform t.eq((select string_agg(tablename, ',' order by tablename) from pg_publication_tables
                where pubname = 'supabase_realtime'), 'messages,notifications', 'only chat/notifications are published');
  raise notice 'PASS mystery mode (API, boards, global, CSV, notifications, realtime)';
end $$;

-- Late uploads and finality ---------------------------------------------------------
do $$
declare
  o uuid := t.new_user('Judge'); a uuid := t.new_user('Late Lucy');
  g uuid; code text; f uuid; p uuid; lb jsonb; csv_before text; csv_after text;
  d5 timestamptz := t.today0() - interval '5 days' + interval '9 hours';
  d1 timestamptz := t.today0() - interval '1 day' + interval '9 hours';
begin
  perform t.login(o);
  g := public.create_group('Finals', null, 'UTC');
  select x.code into code from public.create_invite(g, 24, null) x;
  perform t.login(a); perform public.join_group_with_code(code);
  perform t.logout();
  insert into public.challenges (group_id, name, time_zone, starts_on, ends_on, grace_hours, created_by)
  values (g, 'Last week', 'UTC', current_date - 6, current_date - 4, 48, o) returning id into f;
  insert into public.challenges (group_id, name, time_zone, starts_on, ends_on, grace_hours, created_by)
  values (g, 'Yesterday sprint', 'UTC', current_date - 2, current_date - 1, 48, o) returning id into p;
  insert into public.challenge_participants (challenge_id, user_id) values (f, a), (f, o), (p, a), (p, o);
  perform public.rebuild_user_daily(a, 'UTC', current_date - 10);

  perform t.up(a, 'p', 'phone', d5, 1000);
  perform t.up(a, 'p', 'phone', d1, 2000);
  perform public.refresh_dirty_boards();
  perform t.eq(public.finalize_due_challenges(), 1, 'only the challenge past end + grace is finalised');
  perform t.login(o);
  csv_before := public.export_challenge_csv(f);
  lb := public.get_challenge_leaderboard(f);
  perform t.eq(lb->>'status', 'final', 'status final');
  perform t.logout();

  perform t.up(a, 'p', 'phone', d5 + interval '1 hour', 500);   -- arrives after the result is final
  perform t.up(a, 'p', 'phone', d1 + interval '1 hour', 700);   -- within the grace window
  perform public.refresh_dirty_boards();
  perform t.eq(t.daily(a, 'UTC', current_date - 5), 1500, 'late upload still lands in personal history');
  perform t.login(o);
  lb := public.get_challenge_leaderboard(f);
  perform t.eq((lb->'rows'->0->>'steps')::int, 1000, 'final standings frozen');
  csv_after := public.export_challenge_csv(f);
  perform t.eq(csv_after, csv_before, 'final CSV unchanged by late upload');
  lb := public.get_challenge_leaderboard(p);
  perform t.eq(lb->>'status', 'provisional', 'ended but within grace = provisional');
  perform t.eq((lb->'rows'->0->>'steps')::int, 2700, 'late upload within grace re-scores');
  perform t.logout();
  raise notice 'PASS late uploads / finality';
end $$;
