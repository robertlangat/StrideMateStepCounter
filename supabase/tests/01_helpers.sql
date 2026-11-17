-- Test helpers (test databases only).
set timezone = 'UTC';
create schema if not exists t;
grant usage on schema t to authenticated, anon;

create or replace function t.new_user(p_name text, p_tz text default 'UTC')
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (email, raw_user_meta_data)
  values (lower(p_name) || '-' || left(gen_random_uuid()::text, 8) || '@example.test',
          jsonb_build_object('display_name', p_name))
  returning id into v;
  update public.profiles set time_zone = p_tz where id = v;
  return v;
end $$;

-- Act as an authenticated user (like a Supabase JWT with sub = uid).
create or replace function t.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function t.logout() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create or replace function t.eq(p_actual anyelement, p_expected anyelement, p_msg text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERT FAILED: % (expected %, got %)', p_msg, p_expected, p_actual;
  end if;
end $$;

create or replace function t.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'ASSERT FAILED: %', p_msg; end if;
end $$;

-- Assert that a statement fails with an error message matching p_pattern.
create or replace function t.raises(p_sql text, p_pattern text, p_msg text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ~* p_pattern then return; end if;
    raise exception 'ASSERT FAILED: % (expected error ~ "%", got "%")', p_msg, p_pattern, sqlerrm;
  end;
  raise exception 'ASSERT FAILED: % (expected error ~ "%", but statement succeeded)', p_msg, p_pattern;
end $$;

-- Upload one bucket as p_uid (new batch id each call).
create or replace function t.up(p_uid uuid, p_source text, p_kind text, p_hour timestamptz, p_steps int)
returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform t.login(p_uid);
  r := public.upload_step_buckets(gen_random_uuid(), jsonb_build_array(jsonb_build_object(
         'source_id', p_source, 'source_kind', p_kind, 'bucket_start', p_hour, 'steps', p_steps)));
  perform t.logout();
  return r;
end $$;

create or replace function t.daily(p_uid uuid, p_tz text, p_day date) returns int language sql as $$
  select coalesce((select steps from public.user_daily where user_id = p_uid and tz = p_tz and day = p_day), 0)
$$;

create or replace function t.hour0() returns timestamptz language sql as $$ select date_trunc('hour', now()) $$;
create or replace function t.today0() returns timestamptz language sql as $$ select date_trunc('day', now()) $$;

grant execute on all functions in schema t to authenticated;
