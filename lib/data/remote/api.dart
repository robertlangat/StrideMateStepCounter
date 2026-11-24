import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/source_merge.dart';
import '../sync/sync_core.dart';

/// Typed wrappers around the Supabase RPCs (see supabase/migrations).
class Api implements SyncTransport {
  Api(this.client);
  final SupabaseClient client;

  String? get uid => client.auth.currentUser?.id;

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) => client.rpc(fn, params: params ?? {});

  // ---- steps ------------------------------------------------------------------
  @override
  Future<void> uploadBuckets(String batchId, List<SourceBucket> buckets) async {
    await _rpc('upload_step_buckets', {
      'p_batch_id': batchId,
      'p_buckets': buckets
          .map((b) => {
                'source_id': b.sourceId,
                'source_kind': b.kind.name,
                'bucket_start': b.hourUtc.toIso8601String(),
                'steps': b.steps,
              })
          .toList(),
    });
  }

  Future<List<SourceBucket>> myHourly(DateTime fromUtc, DateTime toUtc) async {
    final rows = await _rpc('get_my_hourly', {'p_from': fromUtc.toIso8601String(), 'p_to': toUtc.toIso8601String()}) as List;
    return rows
        .map((r) => SourceBucket(
              sourceId: 'cloud:restore',
              kind: SourceKind.health,
              hourUtc: DateTime.parse(r['bucket_start'] as String).toUtc(),
              steps: (r['steps'] as num).toInt(),
            ))
        .toList();
  }

  Future<void> setRestDay(String day, bool on) => _rpc('set_rest_day', {'p_day': day, 'p_on': on});

  Future<Set<String>> restDays() async {
    final rows = await client.from('rest_days').select('day') as List;
    return rows.map((r) => r['day'] as String).toSet();
  }

  Future<Map<String, int>> goalHistory() async {
    final rows = await client.from('goal_history').select('effective_from, goal') as List;
    return {for (final r in rows) r['effective_from'] as String: (r['goal'] as num).toInt()};
  }

  Future<void> saveAchievement(String key, String day) async {
    await client.from('user_achievements').upsert({'user_id': uid, 'key': key, 'unlocked_on': day},
        onConflict: 'user_id,key', ignoreDuplicates: true);
  }

  // ---- profile ------------------------------------------------------------------
  Future<Map<String, dynamic>?> myProfile() async {
    if (uid == null) return null;
    return await client.from('profiles').select().eq('id', uid!).maybeSingle();
  }

  Future<void> updateProfile(Map<String, dynamic> fields) async {
    if (uid == null) return;
    await client.from('profiles').update(fields).eq('id', uid!);
  }

  Future<Map<String, dynamic>> exportMyData() async =>
      Map<String, dynamic>.from(await _rpc('export_my_data') as Map);

  Future<void> deleteMyAccount() => _rpc('delete_my_account');

  // ---- groups -----------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> myGroups() async =>
      List<Map<String, dynamic>>.from(await _rpc('get_my_groups') as List);

  Future<String> createGroup(String name, String? description, String timeZone) async =>
      await _rpc('create_group', {'p_name': name, 'p_description': description, 'p_time_zone': timeZone}) as String;

  Future<void> updateGroup(String group, {String? name, String? description, bool? chatEnabled, bool? tauntsEnabled}) =>
      _rpc('update_group_settings', {
        'p_group': group,
        'p_name': name,
        'p_description': description,
        'p_chat_enabled': chatEnabled,
        'p_taunts_enabled': tauntsEnabled,
      });

  Future<Map<String, dynamic>> createInvite(String group, int hours, int? maxUses) async {
    final rows = await _rpc('create_invite', {'p_group': group, 'p_expires_in_hours': hours, 'p_max_uses': maxUses}) as List;
    return Map<String, dynamic>.from(rows.first as Map);
  }

  Future<List<Map<String, dynamic>>> invites(String group) async =>
      List<Map<String, dynamic>>.from(await client
          .from('group_invites')
          .select()
          .eq('group_id', group)
          .isFilter('revoked_at', null)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false) as List);

  Future<void> revokeInvite(String code) => _rpc('revoke_invite', {'p_code': code});

  Future<String> joinGroup(String code) async => await _rpc('join_group_with_code', {'p_code': code}) as String;

  Future<void> setMembershipPrefs(String group, {bool? shareSteps, bool? tauntsMuted}) =>
      _rpc('set_membership_prefs', {'p_group': group, 'p_share_steps': shareSteps, 'p_taunts_muted': tauntsMuted});

  Future<List<Map<String, dynamic>>> members(String group,
          {int limit = 50, String? afterJoined, String? afterUser, String? search}) async =>
      List<Map<String, dynamic>>.from(await _rpc('get_group_members', {
        'p_group': group,
        'p_limit': limit,
        'p_after_joined': afterJoined,
        'p_after_user': afterUser,
        'p_search': (search == null || search.isEmpty) ? null : search,
      }) as List);

  Future<void> setRole(String group, String user, String role) =>
      _rpc('set_member_role', {'p_group': group, 'p_user': user, 'p_role': role});
  Future<void> removeMember(String group, String user) => _rpc('remove_member', {'p_group': group, 'p_user': user});
  Future<void> leaveGroup(String group) => _rpc('leave_group', {'p_group': group});
  Future<void> muteMember(String group, String user, int minutes) =>
      _rpc('mute_member', {'p_group': group, 'p_user': user, 'p_minutes': minutes});

  Future<Map<String, dynamic>> groupLeaderboard(String group, String period,
          {bool previous = false, int limit = 50, int? afterRank, String? afterUser}) async =>
      Map<String, dynamic>.from(await _rpc('get_group_leaderboard', {
        'p_group': group,
        'p_period': period,
        'p_previous': previous,
        'p_limit': limit,
        'p_after_rank': afterRank,
        'p_after_user': afterUser,
      }) as Map);

  // ---- chat -----------------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> messages(String group, {int? beforeId, int limit = 50}) async =>
      List<Map<String, dynamic>>.from(
          await _rpc('get_messages', {'p_group': group, 'p_before_id': beforeId, 'p_limit': limit}) as List);

  Future<void> sendMessage(String group, {String? body, String? presetKey, String? target}) =>
      _rpc('send_message', {'p_group': group, 'p_body': body, 'p_preset_key': presetKey, 'p_target': target});

  Future<List<Map<String, dynamic>>> presets() async =>
      List<Map<String, dynamic>>.from(await client.from('preset_messages').select() as List);

  Future<void> deleteMessage(int id) => _rpc('delete_message', {'p_message': id});
  Future<void> blockUser(String user, bool block) => _rpc('block_user', {'p_user': user, 'p_block': block});
  Future<void> report(String group, {int? messageId, String? userId, required String reason}) =>
      _rpc('report_content', {'p_group': group, 'p_message': messageId, 'p_user': userId, 'p_reason': reason});
  Future<List<Map<String, dynamic>>> reports(String group, {String? status = 'open'}) async =>
      List<Map<String, dynamic>>.from(await _rpc('list_reports', {'p_group': group, 'p_status': status}) as List);
  Future<void> resolveReport(int id, String status) => _rpc('resolve_report', {'p_report': id, 'p_status': status});

  RealtimeChannel subscribeToChat(String group, void Function(Map<String, dynamic> row) onInsert) {
    return client
        .channel('chat:$group')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'group_id', value: group),
          callback: (payload) => onInsert(payload.newRecord),
        )
        .subscribe();
  }

  RealtimeChannel subscribeToNotifications(void Function(Map<String, dynamic> row) onInsert) {
    return client
        .channel('notifications:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: uid ?? ''),
          callback: (payload) => onInsert(payload.newRecord),
        )
        .subscribe();
  }

  Future<void> unsubscribe(RealtimeChannel ch) => client.removeChannel(ch);

  Future<List<Map<String, dynamic>>> notifications() async => List<Map<String, dynamic>>.from(
      await client.from('notifications').select().order('id', ascending: false).limit(50) as List);

  Future<void> markNotificationsRead() async {
    if (uid == null) return;
    await client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', uid!)
        .isFilter('read_at', null);
  }

  // ---- challenges -----------------------------------------------------------------
  Future<List<Map<String, dynamic>>> myChallenges() async =>
      List<Map<String, dynamic>>.from(await _rpc('get_my_challenges') as List);
  Future<List<Map<String, dynamic>>> groupChallenges(String group) async =>
      List<Map<String, dynamic>>.from(await _rpc('get_group_challenges', {'p_group': group}) as List);

  Future<String> createChallenge({
    required String group,
    required String name,
    required String startsOn,
    String? endsOn,
    required String timeZone,
    required bool mystery,
    int? dailyTarget,
    String? description,
  }) async =>
      await _rpc('create_challenge', {
        'p_group': group,
        'p_name': name,
        'p_starts_on': startsOn,
        'p_ends_on': endsOn,
        'p_time_zone': timeZone,
        'p_mystery_mode': mystery,
        'p_daily_target': dailyTarget,
        'p_description': description,
        'p_grace_hours': 48,
      }) as String;

  Future<void> joinChallenge(String id) => _rpc('join_challenge', {'p_challenge': id});
  Future<void> leaveChallenge(String id) => _rpc('leave_challenge', {'p_challenge': id});

  Future<Map<String, dynamic>> challengeLeaderboard(String id, {int limit = 50, int? afterRank, String? afterUser}) async =>
      Map<String, dynamic>.from(await _rpc('get_challenge_leaderboard', {
        'p_challenge': id,
        'p_limit': limit,
        'p_after_rank': afterRank,
        'p_after_user': afterUser,
      }) as Map);

  Future<String> exportChallengeCsv(String id) async => await _rpc('export_challenge_csv', {'p_challenge': id}) as String;

  // ---- global rankings -------------------------------------------------------------
  Future<Map<String, dynamic>> globalLeaderboard(String scope, String period, String date,
          {int limit = 50, int? afterRank, String? afterUser}) async =>
      Map<String, dynamic>.from(await _rpc('get_global_leaderboard', {
        'p_scope': scope,
        'p_period': period,
        'p_date': date,
        'p_limit': limit,
        'p_after_rank': afterRank,
        'p_after_user': afterUser,
      }) as Map);
}

/// Human-readable messages for server error codes raised in the migrations.
String friendlyError(Object e) {
  final raw = e is PostgrestException ? e.message : e is AuthException ? e.message : e.toString();
  const map = {
    'rate_limited': 'You are doing that too often. Please wait a moment and try again.',
    'invite_invalid_or_expired': 'That invite code is invalid, expired or has been revoked.',
    'group_full': 'This group has reached its member limit.',
    'not_a_member': 'You are not a member of this group.',
    'admin_required': 'Only group owners and admins can do that.',
    'owner_required': 'Only the group owner can do that.',
    'insufficient_role': 'Your role does not allow that.',
    'chat_disabled': 'Chat is turned off in this group.',
    'muted_by_admin': 'An admin has muted you in this group for now.',
    'taunts_disabled': 'Taunts are turned off in this group.',
    'target_muted_taunts': 'That member has muted taunts.',
    'blocked': 'You cannot message this person.',
    'rest_day_in_past': 'Rest Days can only be set for today or later.',
    'rest_day_week_limit': 'You can schedule at most 2 Rest Days per week.',
    'challenge_ended': 'This challenge has ended.',
    'start_in_past': 'Challenges cannot start in the past.',
    'invalid_time_zone': 'Please choose a valid time zone.',
    'not_authenticated': 'Please sign in first.',
  };
  for (final entry in map.entries) {
    if (raw.contains(entry.key)) return entry.value;
  }
  if (raw.contains('SocketException') || raw.contains('Failed host lookup') || raw.contains('ClientException')) {
    return 'You appear to be offline. Your steps are safe on this device and will sync later.';
  }
  return raw.length > 160 ? '${raw.substring(0, 160)}…' : raw;
}
