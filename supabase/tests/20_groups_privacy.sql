-- Groups, invites, roles, chat moderation, leaderboards, privacy and deletion.
set timezone = 'UTC';

-- 1. Invites: expiry, revocation, max uses, admin-only creation ----------------
do $$
declare
  o uuid := t.new_user('Owner');
  a uuid := t.new_user('Alice');
  b uuid := t.new_user('Bob');
  c uuid := t.new_user('Cara');
  d uuid := t.new_user('Dev');
  g uuid; c_inv text; c_one text; joined uuid;
begin
  perform t.login(o);
  g := public.create_group('Office walkers', 'Lunch laps', 'Africa/Nairobi');
  select x.code into c_inv from public.create_invite(g, 24, null) x;
  select x.code into c_one from public.create_invite(g, 24, 1) x;
  perform t.login(a);
  joined := public.join_group_with_code(lower(c_inv));     -- codes are case-insensitive
  perform t.eq(joined, g, 'join with valid code');
  perform t.raises(format('select * from public.create_invite(%L, 24, null)', g), 'admin_required', 'members cannot create invites');
  perform t.login(b);
  perform public.join_group_with_code(c_one);
  perform t.login(c);
  perform t.raises(format('select public.join_group_with_code(%L)', c_one), 'invite_invalid_or_expired', 'max_uses enforced');
  perform t.login(o);
  perform public.revoke_invite(c_inv);
  perform t.login(c);
  perform t.raises(format('select public.join_group_with_code(%L)', c_inv), 'invite_invalid_or_expired', 'revoked code refused');
  perform t.logout();
  update public.group_invites set expires_at = now() - interval '1 minute' where code = c_one;
  perform t.login(o);
  select x.code into c_inv from public.create_invite(g, 1, null) x;
  perform t.logout();
  update public.group_invites set expires_at = now() - interval '1 second' where code = c_inv;
  perform t.login(d);
  perform t.raises(format('select public.join_group_with_code(%L)', c_inv), 'invite_invalid_or_expired', 'expired code refused');
  perform t.logout();
  perform t.eq((select member_count from public.groups where id = g), 3, 'member_count maintained');
  raise notice 'PASS invites';
end $$;

-- 2. Roles, ownership transfer, leaving ------------------------------------------
do $$
declare
  o uuid := t.new_user('Olive'); a1 uuid := t.new_user('Ada'); a2 uuid := t.new_user('Abe'); m uuid := t.new_user('Mo');
  g uuid; code text;
begin
  perform t.login(o);
  g := public.create_group('Club', null, 'UTC');
  select x.code into code from public.create_invite(g, 24, null) x;
  perform t.login(a1); perform public.join_group_with_code(code);
  perform t.login(a2); perform public.join_group_with_code(code);
  perform t.login(m);  perform public.join_group_with_code(code);
  perform t.login(o);
  perform public.set_member_role(g, a1, 'admin');
  perform public.set_member_role(g, a2, 'admin');
  perform t.login(a1);
  perform t.raises(format('select public.remove_member(%L, %L)', g, a2), 'insufficient_role', 'admin cannot remove admin');
  perform t.raises(format('select public.set_member_role(%L, %L, %L)', g, m, 'admin'), 'owner_required', 'admin cannot promote');
  perform public.remove_member(g, m);
  perform t.login(o);
  perform public.leave_group(g);                          -- owner leaves: longest-standing admin inherits
  perform t.logout();
  perform t.eq((select owner_id from public.groups where id = g), a1, 'ownership passes to oldest admin');
  perform t.eq((select count(*)::int from public.group_members where group_id = g and role = 'owner'), 1, 'exactly one owner');
  raise notice 'PASS roles / ownership';
end $$;

-- 3. Chat: blocking, taunt muting/disabling, rate limits, moderation, reports ----
do $$
declare
  o uuid := t.new_user('Host'); x uuid := t.new_user('Xena'); y uuid := t.new_user('Yuri'); outsider uuid := t.new_user('Out');
  g uuid; code text; mid bigint; rid bigint; n int; i int;
begin
  perform t.login(o);
  g := public.create_group('Chatty', null, 'UTC');
  select z.code into code from public.create_invite(g, 24, null) z;
  perform t.login(x); perform public.join_group_with_code(code);
  perform t.login(y); perform public.join_group_with_code(code);

  perform t.login(x);
  mid := public.send_message(g, 'Morning walk anyone?');
  perform public.send_message(g, null, 'cheer_high_five', y);
  perform t.login(y);
  perform t.eq((select count(*)::int from public.messages where group_id = g), 2, 'member sees messages via RLS');
  perform public.block_user(x, true);
  perform t.eq((select count(*)::int from public.messages where group_id = g), 0, 'blocked author hidden by RLS (and realtime)');
  perform t.eq((select count(*)::int from public.get_messages(g)), 0, 'blocked author hidden in RPC');
  perform t.login(x);
  perform t.raises(format('select public.send_message(%L, null, %L, %L)', g, 'taunt_couch', y), 'blocked', 'cannot taunt someone who blocked you');
  perform t.login(y);
  perform public.block_user(x, false);
  perform public.set_membership_prefs(g, null, true);     -- Yuri mutes taunts
  perform t.login(x);
  perform t.raises(format('select public.send_message(%L, null, %L, %L)', g, 'taunt_couch', y), 'target_muted_taunts', 'muted target cannot be taunted');
  perform public.send_message(g, null, 'taunt_snail', o);
  perform t.login(y);
  perform t.eq((select count(*)::int from public.messages where group_id = g and kind = 'taunt'), 0, 'taunts hidden for user who muted them');
  perform t.login(o);
  perform t.eq((select count(*)::int from public.notifications where kind = 'taunt'), 1, 'taunt target notified');
  perform public.update_group_settings(g, null, null, null, false);
  perform t.login(x);
  perform t.raises(format('select public.send_message(%L, null, %L, %L)', g, 'taunt_snail', o), 'taunts_disabled', 'admin disabled taunts');
  perform t.raises(format('select public.send_message(%L, null, %L, %L)', g, 'not_a_preset', o), 'unknown_preset', 'only preset cheers/taunts');

  perform t.login(outsider);
  perform t.eq((select count(*)::int from public.messages where group_id = g), 0, 'non-member cannot read chat');
  perform t.raises(format('select public.send_message(%L, %L)', g, 'hi'), 'not_a_member', 'non-member cannot post');

  perform t.login(y);
  rid := public.report_content(g, mid, null, 'Spam');
  perform t.raises(format('select * from public.list_reports(%L)', g), 'admin_required', 'members cannot list reports');
  perform t.login(o);
  perform t.eq((select count(*)::int from public.list_reports(g)), 1, 'admin sees report');
  perform public.delete_message(mid);
  perform public.resolve_report(rid, 'actioned');
  perform public.mute_member(g, x, 60);
  perform t.login(x);
  perform t.raises(format('select public.send_message(%L, %L)', g, 'hello?'), 'muted_by_admin', 'muted member cannot post');
  perform t.login(y);
  perform t.eq((select count(*)::int from public.get_messages(g) m where m.id = mid), 0, 'deleted message gone');
  for i in 1..20 loop perform public.send_message(g, 'msg ' || i); end loop;
  perform t.raises(format('select public.send_message(%L, %L)', g, 'one too many'), 'rate_limited', 'message rate limit');
  perform t.logout();
  raise notice 'PASS chat / moderation';
end $$;

-- 4. Leaderboards: ties, own rank outside the page, keyset pagination, privacy ----
do $$
declare
  o uuid := t.new_user('Lead'); u2 uuid := t.new_user('Tie A'); u3 uuid := t.new_user('Tie B');
  u4 uuid := t.new_user('Last'); hid uuid := t.new_user('Hidden'); priv uuid := t.new_user('Private');
  outsider uuid := t.new_user('Nosy');
  g uuid; g2 uuid; code text; code2 text; lb jsonb; lb2 jsonb; h timestamptz := t.hour0();
begin
  perform t.login(o);
  g := public.create_group('Board', null, 'UTC');
  g2 := public.create_group('Other board', null, 'UTC');
  select x.code into code from public.create_invite(g, 24, null) x;
  select x.code into code2 from public.create_invite(g2, 24, null) x;
  foreach o in array array[u2, u3, u4, hid, priv] loop
    perform t.login(o); perform public.join_group_with_code(code);
  end loop;
  perform t.login(hid); perform public.join_group_with_code(code2);
  perform public.set_membership_prefs(g, false, null);   -- hide steps from group g only
  perform t.logout();
  update public.profiles set steps_private = true where id = priv;
  select owner_id into o from public.groups where id = g;
  perform t.up(o, 'p', 'phone', h, 9000);
  perform t.up(u2, 'p', 'phone', h, 5000);
  perform t.up(u3, 'p', 'phone', h, 5000);
  perform t.up(u4, 'p', 'phone', h, 1000);
  perform t.up(hid, 'p', 'phone', h, 20000 - 15000 + 7000);
  perform t.up(priv, 'p', 'phone', h, 8000);
  perform public.refresh_dirty_boards();

  perform t.login(u4);
  lb := public.get_group_leaderboard(g, 'day', false, 2);
  perform t.eq(jsonb_array_length(lb->'rows'), 2, 'page size respected');
  perform t.eq((lb->'rows'->0->>'rank')::int, 1, 'leader rank 1');
  perform t.eq((lb->'me'->>'rank')::int, 4, 'own rank shown although outside the page');
  perform t.eq((lb->'me'->>'live_steps')::int, 1000, 'own live steps');
  perform t.eq((lb->>'total_ranked')::int, 4, 'hidden and private members are not ranked');
  lb2 := public.get_group_leaderboard(g, 'day', false, 2,
           (lb->'rows'->1->>'rank')::int, (lb->'rows'->1->>'user_id')::uuid);
  perform t.eq((lb2->'rows'->0->>'rank')::int, 2, 'tie: equal totals share rank 2');
  perform t.eq((lb2->'rows'->1->>'rank')::int, 4, 'competition ranking skips to 4');
  perform t.eq((lb->'rows'->1->>'rank')::int, 2, 'first tied row also rank 2');
  perform t.ok(not (lb::text || lb2::text) like '%' || hid::text || '%', 'member hiding steps from g absent from g board');
  perform t.ok(not (lb::text || lb2::text) like '%' || priv::text || '%', 'private user absent');
  lb := public.get_group_leaderboard(g, 'week');
  perform t.eq((lb->'rows'->0->>'steps')::int, 9000, 'weekly board');
  perform t.login(o);
  lb := public.get_group_leaderboard(g2, 'day');
  perform t.eq((lb->'rows'->0->>'user_id')::uuid, hid, 'same user visible in the group they share with');
  perform t.login(hid);
  lb := public.get_group_leaderboard(g, 'day');
  perform t.eq((lb->'me'->>'ranked')::boolean, false, 'non-sharing member sees own total but is unranked');
  perform t.eq((lb->'me'->>'live_steps')::int, 12000, 'own total still visible to self');

  -- direct table access is closed; outsiders are refused
  perform t.login(u2);
  perform t.raises('select count(*) from public.group_rankings', 'permission denied', 'rankings table not readable directly');
  perform t.raises('select count(*) from public.challenge_standings', 'permission denied', 'standings table not readable directly');
  perform t.eq((select count(*)::int from public.user_daily where user_id <> u2), 0, 'cannot read others daily totals');
  perform t.eq((select count(*)::int from public.step_buckets where user_id <> u2), 0, 'cannot read others buckets');
  perform t.eq((select count(*)::int from public.profiles where id <> u2), 0, 'cannot read others profiles');
  perform t.raises(format('update public.profiles set flagged_at = null where id = %L', u2), 'permission denied', 'cannot clear own flag');
  perform t.login(outsider);
  perform t.raises(format('select public.get_group_leaderboard(%L)', g), 'not_a_member', 'non-member refused');
  perform t.eq((select count(*)::int from public.groups where id = g), 0, 'non-member cannot see group row');
  perform t.logout();
  perform set_config('role', 'anon', true);
  perform t.raises('select count(*) from public.user_daily', 'permission denied', 'anon has no table access');
  perform t.logout();
  raise notice 'PASS leaderboards / ties / visibility';
end $$;

-- 5. Global & country rankings are opt-in, flag-aware --------------------------
do $$
declare
  a uuid := t.new_user('Glob A', 'Africa/Nairobi'); b uuid := t.new_user('Glob B'); c uuid := t.new_user('Not opted');
  lb jsonb;
begin
  update public.profiles set global_rankings_opt_in = true, country_code = 'KE' where id in (a, b);
  update public.profiles set flagged_at = null, flag_reason = null where id in (a, b);
  perform t.up(a, 'p', 'phone', t.hour0(), 4321);
  perform t.up(b, 'p', 'phone', t.hour0(), 1234);
  perform t.up(c, 'p', 'phone', t.hour0(), 99999 - 90000);
  perform public.refresh_global_rankings();
  perform t.login(b);
  lb := public.get_global_leaderboard('KE', 'day', (now() at time zone 'Africa/Nairobi')::date);
  perform t.ok(lb::text like '%' || a::text || '%', 'opted-in user ranked in country');
  perform t.ok(lb::text not like '%' || c::text || '%', 'non-opted user absent');
  perform t.logout();
  update public.profiles set flagged_at = now() where id = a;
  perform public.refresh_global_rankings();
  perform t.login(b);
  lb := public.get_global_leaderboard('GLOBAL', 'week', current_date);
  perform t.ok(lb::text not like '%' || a::text || '%', 'flagged (implausible) user excluded from global boards');
  perform t.logout();
  raise notice 'PASS global rankings';
end $$;

-- 6. Personal export and account deletion ------------------------------------------
do $$
declare
  o uuid := t.new_user('Leaver'); adm uuid := t.new_user('Heir'); solo uuid; g uuid; g2 uuid; code text; ex jsonb;
begin
  perform t.login(o);
  g := public.create_group('Inherited', null, 'UTC');
  g2 := public.create_group('Solo', null, 'UTC');
  select x.code into code from public.create_invite(g, 24, null) x;
  perform t.login(adm); perform public.join_group_with_code(code);
  perform t.login(o);
  perform public.set_member_role(g, adm, 'admin');
  perform public.send_message(g, 'bye all');
  perform t.logout();
  perform t.up(o, 'p', 'phone', t.hour0(), 321);
  perform t.login(o);
  ex := public.export_my_data();
  perform t.eq(jsonb_array_length(ex->'hourly_by_source'), 1, 'export contains own buckets');
  perform t.eq(jsonb_array_length(ex->'groups'), 2, 'export contains memberships');
  perform t.ok(not ex->'profile' ? 'flagged_at', 'internal moderation fields not exported');
  perform public.delete_my_account();
  perform t.logout();
  perform t.eq((select count(*)::int from auth.users where id = o), 0, 'auth user deleted');
  perform t.eq((select count(*)::int from public.step_buckets where user_id = o), 0, 'step data deleted');
  perform t.eq((select count(*)::int from public.user_daily where user_id = o), 0, 'daily data deleted');
  perform t.eq((select count(*)::int from public.messages where user_id = o), 0, 'authored messages deleted');
  perform t.eq((select owner_id from public.groups where id = g), adm, 'group handed to admin');
  perform t.eq((select count(*)::int from public.groups where id = g2), 0, 'empty group removed');
  raise notice 'PASS export / account deletion';
end $$;
