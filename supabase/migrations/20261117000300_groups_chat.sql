-- Private groups, invites, roles, chat, cheers/taunts, blocking, reporting, moderation.

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 60),
  description text check (description is null or char_length(description) <= 280),
  owner_id uuid not null references auth.users (id),
  time_zone text not null default 'UTC',
  chat_enabled boolean not null default true,
  taunts_enabled boolean not null default true,
  member_count int not null default 0,
  max_members int not null default 15000 check (max_members between 2 and 15000),
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.group_role not null default 'member',
  share_steps boolean not null default true,
  taunts_muted boolean not null default false,
  chat_muted_until timestamptz,
  joined_at timestamptz not null default clock_timestamp(),
  primary key (group_id, user_id)
);
create index group_members_user on public.group_members (user_id);
create index group_members_page on public.group_members (group_id, joined_at, user_id);
create unique index group_one_owner on public.group_members (group_id) where role = 'owner';

create table public.group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  code text not null unique,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  max_uses int check (max_uses is null or max_uses > 0),
  uses int not null default 0,
  revoked_at timestamptz
);
create index group_invites_group on public.group_invites (group_id);

create table public.preset_messages (
  key text primary key,
  kind public.message_kind not null check (kind in ('cheer', 'taunt')),
  body text not null
);

insert into public.preset_messages (key, kind, body) values
  ('cheer_keep_going', 'cheer', 'Keep going, {target}! Every step counts.'),
  ('cheer_crushed_it', 'cheer', '{target}, you crushed it today!'),
  ('cheer_walk_buddy', 'cheer', 'Proud to be your walking buddy, {target}.'),
  ('cheer_high_five', 'cheer', 'High five, {target}!'),
  ('taunt_sneakers', 'taunt', '{target}, your sneakers are filing a missing-person report.'),
  ('taunt_couch', 'taunt', '{target}, the couch called. It says you two need some space.'),
  ('taunt_catch_me', 'taunt', 'Catch me if you can, {target}!'),
  ('taunt_snail', 'taunt', 'A snail just lapped you, {target}. Politely.');

create table public.messages (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid references auth.users (id) on delete set null,
  kind public.message_kind not null,
  body text not null check (char_length(body) between 1 and 1000),
  preset_key text references public.preset_messages (key),
  target_user_id uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid
);
create index messages_group_page on public.messages (group_id, id desc);

create table public.blocks (
  blocker_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked on public.blocks (blocked_id);

create table public.reports (
  id bigint generated always as identity primary key,
  reporter_id uuid references auth.users (id) on delete set null,
  group_id uuid references public.groups (id) on delete cascade,
  message_id bigint references public.messages (id) on delete set null,
  reported_user_id uuid references auth.users (id) on delete set null,
  reason text not null check (char_length(reason) between 1 and 500),
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at timestamptz not null default now(),
  resolved_by uuid,
  resolved_at timestamptz
);
create index reports_group_open on public.reports (group_id, status, created_at desc);

create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index notifications_user on public.notifications (user_id, id desc);

-- ---------------------------------------------------------------------------
-- Membership helpers
-- ---------------------------------------------------------------------------
create or replace function public.group_role_of(p_group uuid, p_uid uuid)
returns public.group_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select role from public.group_members where group_id = p_group and user_id = p_uid
$$;

create or replace function public.is_group_member(p_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.group_members where group_id = p_group and user_id = auth.uid())
$$;

create or replace function public.is_group_admin(p_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(public.group_role_of(p_group, auth.uid()) in ('owner', 'admin'), false)
$$;

create or replace function public.require_member(p_group uuid)
returns public.group_role
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role public.group_role := public.group_role_of(p_group, public.require_uid());
begin
  if v_role is null then
    raise exception 'not_a_member' using errcode = '42501';
  end if;
  return v_role;
end
$$;

create or replace function public.require_admin(p_group uuid)
returns public.group_role
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role public.group_role := public.require_member(p_group);
begin
  if v_role not in ('owner', 'admin') then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  return v_role;
end
$$;

create or replace function public.group_members_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    update public.groups set member_count = member_count + 1 where id = new.group_id;
  elsif tg_op = 'DELETE' then
    update public.groups set member_count = greatest(member_count - 1, 0) where id = old.group_id;
  end if;
  return null;
end
$$;
create trigger group_members_count after insert or delete on public.group_members
for each row execute function public.group_members_count();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_invites enable row level security;
alter table public.preset_messages enable row level security;
alter table public.messages enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;
alter table public.notifications enable row level security;

create policy groups_member_select on public.groups for select to authenticated
  using (public.is_group_member(id));
-- Members may read their own membership row; member lists go through get_group_members().
create policy members_self_select on public.group_members for select to authenticated
  using (user_id = auth.uid());
create policy invites_admin_select on public.group_invites for select to authenticated
  using (public.is_group_admin(group_id));
create policy presets_read on public.preset_messages for select to authenticated using (true);
-- Chat rows are visible to members only, minus blocked authors and muted taunts.
-- Supabase Realtime evaluates this policy per subscriber.
create policy messages_member_select on public.messages for select to authenticated
  using (
    deleted_at is null
    and public.is_group_member(group_id)
    and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = messages.user_id)
    and not (kind = 'taunt' and exists (
      select 1 from public.group_members gm
      where gm.group_id = messages.group_id and gm.user_id = auth.uid() and gm.taunts_muted))
  );
create policy blocks_own on public.blocks for select to authenticated using (blocker_id = auth.uid());
create policy notifications_own_select on public.notifications for select to authenticated
  using (user_id = auth.uid());
create policy notifications_own_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Group RPCs
-- ---------------------------------------------------------------------------
create or replace function public.create_group(p_name text, p_description text default null, p_time_zone text default 'UTC')
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_id uuid;
begin
  perform public.enforce_rate_limit('create_group', 10, interval '1 day');
  if public.valid_tz(p_time_zone) is null then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;
  insert into public.groups (name, description, owner_id, time_zone)
  values (btrim(p_name), nullif(btrim(p_description), ''), v_uid, p_time_zone)
  returning id into v_id;
  insert into public.group_members (group_id, user_id, role) values (v_id, v_uid, 'owner');
  perform public.on_member_joined(v_id, v_uid);
  return v_id;
end
$$;

-- Replaced in 000400 to backfill zone totals and mark boards dirty.
create or replace function public.on_member_joined(p_group uuid, p_uid uuid)
returns void language sql security definer set search_path = public, pg_temp as $$ select $$;

create or replace function public.update_group_settings(
  p_group uuid, p_name text default null, p_description text default null,
  p_chat_enabled boolean default null, p_taunts_enabled boolean default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_admin(p_group);
  update public.groups set
    name = coalesce(nullif(btrim(p_name), ''), name),
    description = coalesce(p_description, description),
    chat_enabled = coalesce(p_chat_enabled, chat_enabled),
    taunts_enabled = coalesce(p_taunts_enabled, taunts_enabled)
  where id = p_group;
end
$$;

create or replace function public.get_my_groups()
returns table (id uuid, name text, description text, role public.group_role, member_count int,
               time_zone text, chat_enabled boolean, taunts_enabled boolean,
               share_steps boolean, taunts_muted boolean)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select g.id, g.name, g.description, m.role, g.member_count, g.time_zone,
         g.chat_enabled, g.taunts_enabled, m.share_steps, m.taunts_muted
  from public.group_members m join public.groups g on g.id = m.group_id
  where m.user_id = auth.uid()
  order by g.name
$$;

create or replace function public.create_invite(p_group uuid, p_expires_in_hours int default 168, p_max_uses int default null)
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
  v_exp timestamptz;
begin
  perform public.require_admin(p_group);
  perform public.enforce_rate_limit('create_invite', 30, interval '1 hour');
  if p_expires_in_hours is null or p_expires_in_hours < 1 or p_expires_in_hours > 720 then
    raise exception 'invalid_expiry' using errcode = '22023';
  end if;
  v_exp := now() + make_interval(hours => p_expires_in_hours);
  loop
    v_code := public.random_code(10);
    begin
      insert into public.group_invites (group_id, code, created_by, expires_at, max_uses)
      values (p_group, v_code, auth.uid(), v_exp, p_max_uses);
      exit;
    exception when unique_violation then
      -- astronomically unlikely; try another code
    end;
  end loop;
  return query select v_code, v_exp;
end
$$;

create or replace function public.revoke_invite(p_code text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group uuid;
begin
  select group_id into v_group from public.group_invites where code = upper(btrim(p_code));
  if v_group is null then
    raise exception 'invite_not_found' using errcode = 'P0002';
  end if;
  perform public.require_admin(v_group);
  update public.group_invites set revoked_at = now() where code = upper(btrim(p_code)) and revoked_at is null;
end
$$;

create or replace function public.join_group_with_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_inv public.group_invites;
  v_group public.groups;
begin
  -- Throttles code guessing as well as legitimate retries.
  perform public.enforce_rate_limit('join_group', 10, interval '10 minutes');
  select * into v_inv from public.group_invites where code = upper(btrim(p_code)) for update;
  if not found or v_inv.revoked_at is not null or v_inv.expires_at <= now()
     or (v_inv.max_uses is not null and v_inv.uses >= v_inv.max_uses) then
    raise exception 'invite_invalid_or_expired' using errcode = 'P0002';
  end if;
  select * into v_group from public.groups where id = v_inv.group_id for update;
  if exists (select 1 from public.group_members where group_id = v_group.id and user_id = v_uid) then
    return v_group.id;
  end if;
  if exists (select 1 from public.blocks b join public.group_members m on m.user_id = b.blocker_id
             where m.group_id = v_group.id and m.role = 'owner' and b.blocked_id = v_uid) then
    raise exception 'invite_invalid_or_expired' using errcode = 'P0002';
  end if;
  if v_group.member_count >= v_group.max_members then
    raise exception 'group_full' using errcode = '23514';
  end if;
  insert into public.group_members (group_id, user_id, role) values (v_group.id, v_uid, 'member');
  update public.group_invites set uses = uses + 1 where id = v_inv.id;
  perform public.on_member_joined(v_group.id, v_uid);
  return v_group.id;
end
$$;

create or replace function public.set_membership_prefs(p_group uuid, p_share_steps boolean default null, p_taunts_muted boolean default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_member(p_group);
  update public.group_members set
    share_steps = coalesce(p_share_steps, share_steps),
    taunts_muted = coalesce(p_taunts_muted, taunts_muted)
  where group_id = p_group and user_id = auth.uid();
  perform public.mark_user_boards_dirty(auth.uid());
end
$$;

-- Paginated member list (keyset on joined_at, user_id). Step totals are not
-- returned here; they come from leaderboards, which apply visibility rules.
create or replace function public.get_group_members(
  p_group uuid, p_limit int default 50, p_after_joined timestamptz default null, p_after_user uuid default null,
  p_search text default null)
returns table (user_id uuid, display_name text, avatar_emoji text, role public.group_role,
               joined_at timestamptz, chat_muted_until timestamptz, blocked_by_me boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean;
begin
  perform public.require_member(p_group);
  v_admin := public.is_group_admin(p_group);
  return query
  select m.user_id, p.display_name, p.avatar_emoji, m.role, m.joined_at,
         case when v_admin then m.chat_muted_until end,
         exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = m.user_id)
  from public.group_members m join public.profiles p on p.id = m.user_id
  where m.group_id = p_group
    and (p_after_joined is null or (m.joined_at, m.user_id) > (p_after_joined, p_after_user))
    and (p_search is null or p.display_name ilike '%' || replace(replace(p_search, '%', ''), '_', '') || '%')
  order by m.joined_at, m.user_id
  limit least(greatest(p_limit, 1), 200);
end
$$;

create or replace function public.set_member_role(p_group uuid, p_user uuid, p_role public.group_role)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_my public.group_role := public.require_admin(p_group);
  v_their public.group_role := public.group_role_of(p_group, p_user);
begin
  if v_their is null then
    raise exception 'not_a_member' using errcode = 'P0002';
  end if;
  if p_role = 'owner' then
    -- Ownership transfer: owner only. Previous owner becomes admin.
    if v_my <> 'owner' then raise exception 'owner_required' using errcode = '42501'; end if;
    update public.group_members set role = 'admin' where group_id = p_group and user_id = auth.uid();
    update public.group_members set role = 'owner' where group_id = p_group and user_id = p_user;
    update public.groups set owner_id = p_user where id = p_group;
    return;
  end if;
  if v_their = 'owner' then
    raise exception 'cannot_change_owner' using errcode = '42501';
  end if;
  if v_my = 'admin' and (v_their = 'admin' or p_role = 'admin') then
    raise exception 'owner_required' using errcode = '42501';
  end if;
  update public.group_members set role = p_role where group_id = p_group and user_id = p_user;
end
$$;

create or replace function public.remove_member(p_group uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_my public.group_role := public.require_admin(p_group);
  v_their public.group_role := public.group_role_of(p_group, p_user);
begin
  if v_their is null then return; end if;
  if v_their = 'owner' or (v_their = 'admin' and v_my <> 'owner') then
    raise exception 'insufficient_role' using errcode = '42501';
  end if;
  delete from public.group_members where group_id = p_group and user_id = p_user;
  delete from public.challenge_participants cp using public.challenges c
   where cp.challenge_id = c.id and c.group_id = p_group and cp.user_id = p_user;
  perform public.mark_group_dirty(p_group);
end
$$;

create or replace function public.leave_group(p_group uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_role public.group_role := public.require_member(p_group);
  v_next uuid;
begin
  if v_role = 'owner' then
    select user_id into v_next from public.group_members
    where group_id = p_group and user_id <> v_uid
    order by (role = 'admin') desc, joined_at, user_id limit 1;
    if v_next is null then
      delete from public.groups where id = p_group;  -- last member leaves: group is removed
      return;
    end if;
    delete from public.group_members where group_id = p_group and user_id = v_uid;
    update public.group_members set role = 'owner' where group_id = p_group and user_id = v_next;
    update public.groups set owner_id = v_next where id = p_group;
  end if;
  delete from public.group_members where group_id = p_group and user_id = v_uid;
  delete from public.challenge_participants cp using public.challenges c
   where cp.challenge_id = c.id and c.group_id = p_group and cp.user_id = v_uid;
  perform public.mark_group_dirty(p_group);
end
$$;

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------
create or replace function public.send_message(p_group uuid, p_body text default null,
  p_preset_key text default null, p_target uuid default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
  v_group public.groups;
  v_member public.group_members;
  v_preset public.preset_messages;
  v_kind public.message_kind := 'text';
  v_body text;
  v_id bigint;
  v_target_name text;
  v_sender_name text;
begin
  select * into v_member from public.group_members where group_id = p_group and user_id = v_uid;
  if not found then raise exception 'not_a_member' using errcode = '42501'; end if;
  select * into v_group from public.groups where id = p_group;
  if not v_group.chat_enabled then raise exception 'chat_disabled' using errcode = '42501'; end if;
  if v_member.chat_muted_until is not null and v_member.chat_muted_until > now() then
    raise exception 'muted_by_admin' using errcode = '42501';
  end if;
  perform public.enforce_rate_limit('send_message', 20, interval '1 minute');
  perform public.enforce_rate_limit('send_message_hour', 300, interval '1 hour');

  if p_preset_key is not null then
    select * into v_preset from public.preset_messages where key = p_preset_key;
    if not found then raise exception 'unknown_preset' using errcode = '22023'; end if;
    v_kind := v_preset.kind;
    if p_target is null or not exists (select 1 from public.group_members where group_id = p_group and user_id = p_target) then
      raise exception 'target_not_in_group' using errcode = '22023';
    end if;
    if p_target = v_uid then raise exception 'cannot_target_self' using errcode = '22023'; end if;
    if v_kind = 'taunt' then
      if not v_group.taunts_enabled then raise exception 'taunts_disabled' using errcode = '42501'; end if;
      if exists (select 1 from public.group_members where group_id = p_group and user_id = p_target and taunts_muted) then
        raise exception 'target_muted_taunts' using errcode = '42501';
      end if;
    end if;
    if exists (select 1 from public.blocks where (blocker_id = p_target and blocked_id = v_uid)
                                         or (blocker_id = v_uid and blocked_id = p_target)) then
      raise exception 'blocked' using errcode = '42501';
    end if;
    select display_name into v_target_name from public.profiles where id = p_target;
    v_body := replace(v_preset.body, '{target}', coalesce(v_target_name, 'friend'));
  else
    v_body := btrim(coalesce(p_body, ''));
    if char_length(v_body) = 0 or char_length(v_body) > 1000 then
      raise exception 'invalid_message' using errcode = '22023';
    end if;
  end if;

  insert into public.messages (group_id, user_id, kind, body, preset_key, target_user_id)
  values (p_group, v_uid, v_kind, v_body, p_preset_key, p_target)
  returning id into v_id;

  if p_target is not null then
    select display_name into v_sender_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, kind, title, body, data)
    values (p_target, v_kind::text,
            case v_kind when 'cheer' then v_sender_name || ' cheered you on'
                        else v_sender_name || ' sent you a taunt' end,
            v_body, jsonb_build_object('group_id', p_group, 'message_id', v_id));
  end if;
  return v_id;
end
$$;

create or replace function public.get_messages(p_group uuid, p_before_id bigint default null, p_limit int default 50)
returns table (id bigint, user_id uuid, display_name text, kind public.message_kind, body text,
               target_user_id uuid, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_muted boolean;
begin
  perform public.require_member(p_group);
  select gm.taunts_muted into v_muted from public.group_members gm where gm.group_id = p_group and gm.user_id = auth.uid();
  return query
  select m.id, m.user_id, coalesce(p.display_name, 'Former member'), m.kind, m.body, m.target_user_id, m.created_at
  from public.messages m left join public.profiles p on p.id = m.user_id
  where m.group_id = p_group and m.deleted_at is null
    and (p_before_id is null or m.id < p_before_id)
    and not (m.kind = 'taunt' and v_muted)
    and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = m.user_id)
  order by m.id desc
  limit least(greatest(p_limit, 1), 100);
end
$$;

create or replace function public.delete_message(p_message bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_msg public.messages;
begin
  select * into v_msg from public.messages where id = p_message;
  if not found then return; end if;
  if v_msg.user_id is distinct from auth.uid() then
    perform public.require_admin(v_msg.group_id);
  end if;
  update public.messages set deleted_at = now(), deleted_by = auth.uid() where id = p_message;
end
$$;

create or replace function public.mute_member(p_group uuid, p_user uuid, p_minutes int)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_my public.group_role := public.require_admin(p_group);
  v_their public.group_role := public.group_role_of(p_group, p_user);
begin
  if v_their is null then raise exception 'not_a_member' using errcode = 'P0002'; end if;
  if v_their = 'owner' or (v_their = 'admin' and v_my <> 'owner') then
    raise exception 'insufficient_role' using errcode = '42501';
  end if;
  update public.group_members
  set chat_muted_until = case when p_minutes <= 0 then null else now() + make_interval(mins => least(p_minutes, 60 * 24 * 30)) end
  where group_id = p_group and user_id = p_user;
end
$$;

create or replace function public.block_user(p_user uuid, p_block boolean default true)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public.require_uid();
begin
  if p_block then
    insert into public.blocks (blocker_id, blocked_id) values (v_uid, p_user) on conflict do nothing;
  else
    delete from public.blocks where blocker_id = v_uid and blocked_id = p_user;
  end if;
end
$$;

create or replace function public.report_content(p_group uuid, p_message bigint, p_user uuid, p_reason text)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  perform public.require_member(p_group);
  perform public.enforce_rate_limit('report', 20, interval '1 hour');
  if p_message is not null and not exists (select 1 from public.messages where id = p_message and group_id = p_group) then
    raise exception 'message_not_in_group' using errcode = '22023';
  end if;
  insert into public.reports (reporter_id, group_id, message_id, reported_user_id, reason)
  values (auth.uid(), p_group, p_message,
          coalesce(p_user, (select user_id from public.messages where id = p_message)),
          left(btrim(p_reason), 500))
  returning id into v_id;
  return v_id;
end
$$;

create or replace function public.list_reports(p_group uuid, p_status text default 'open')
returns table (id bigint, message_id bigint, message_body text, reported_user_id uuid, reported_name text,
               reporter_name text, reason text, status text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_admin(p_group);
  return query
  select r.id, r.message_id, m.body, r.reported_user_id, rp.display_name, rr.display_name, r.reason, r.status, r.created_at
  from public.reports r
  left join public.messages m on m.id = r.message_id
  left join public.profiles rp on rp.id = r.reported_user_id
  left join public.profiles rr on rr.id = r.reporter_id
  where r.group_id = p_group and (p_status is null or r.status = p_status)
  order by r.created_at desc
  limit 200;
end
$$;

create or replace function public.resolve_report(p_report bigint, p_status text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group uuid;
begin
  if p_status not in ('actioned', 'dismissed') then raise exception 'invalid_status' using errcode = '22023'; end if;
  select group_id into v_group from public.reports where id = p_report;
  if v_group is null then raise exception 'report_not_found' using errcode = 'P0002'; end if;
  perform public.require_admin(v_group);
  update public.reports set status = p_status, resolved_by = auth.uid(), resolved_at = now() where id = p_report;
end
$$;
