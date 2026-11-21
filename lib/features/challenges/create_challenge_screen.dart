import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../domain/day_key.dart';
import '../../widgets/common.dart';
import '../../widgets/time_zone_field.dart';

class CreateChallengeScreen extends StatefulWidget {
  const CreateChallengeScreen({super.key, required this.groupId, required this.groupTimeZone});
  final String groupId;
  final String groupTimeZone;

  @override
  State<CreateChallengeScreen> createState() => _CreateChallengeScreenState();
}

class _CreateChallengeScreenState extends State<CreateChallengeScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  DateTime _start = startOfDay(DateTime.now());
  DateTime? _end = addDays(startOfDay(DateTime.now()), 6);
  late String _tz = widget.groupTimeZone;
  String _deviceZone = 'UTC';
  bool _mystery = false;
  int? _target;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    FlutterTimezone.getLocalTimezone().then((z) {
      if (mounted) setState(() => _deviceZone = z);
    });
  }

  Future<void> _pick(bool start) async {
    final now = startOfDay(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      firstDate: start ? now : _start,
      lastDate: addDays(now, 365),
      initialDate: start ? _start : (_end ?? addDays(_start, 6)),
    );
    if (picked == null) return;
    setState(() {
      if (start) {
        _start = picked;
        if (_end != null && _end!.isBefore(picked)) _end = picked;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      showSnack(context, 'Give your challenge a name.');
      return;
    }
    setState(() => _busy = true);
    try {
      await services.api!.createChallenge(
        group: widget.groupId,
        name: _name.text.trim(),
        description: _desc.text.trim(),
        startsOn: dayKey(_start),
        endsOn: _end == null ? null : dayKey(_end!),
        timeZone: _tz,
        mystery: _mystery,
        dailyTarget: _target,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = DateFormat.yMMMd();
    return Scaffold(
      appBar: AppBar(title: const Text('New challenge')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, maxLength: 80, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: _desc, maxLength: 500, maxLines: 3,
            decoration: const InputDecoration(labelText: 'Description (optional)', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        ListTile(title: const Text('Starts'), trailing: Text(f.format(_start)), onTap: () => _pick(true)),
        SwitchListTile(
          title: const Text('Ongoing (no end date)'),
          value: _end == null,
          onChanged: (v) => setState(() => _end = v ? null : addDays(_start, 6)),
        ),
        if (_end != null) ListTile(title: const Text('Ends'), trailing: Text(f.format(_end!)), onTap: () => _pick(false)),
        const SizedBox(height: 8),
        TimeZoneField(value: _tz, deviceZone: _deviceZone, onChanged: (z) => setState(() => _tz = z)),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Mystery Mode 🕵️'),
          subtitle: const Text('Other participants\' steps for the current day — and any ranking that would reveal '
              'them — stay hidden until midnight in the challenge time zone. Applies to the app, live updates, '
              'notifications and CSV exports.'),
          value: _mystery,
          onChanged: (v) => setState(() => _mystery = v),
        ),
        DropdownButtonFormField<int?>(
          value: _target,
          decoration: const InputDecoration(labelText: 'Daily target (optional)', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: null, child: Text('None — most steps wins')),
            DropdownMenuItem(value: 6000, child: Text('6,000 steps a day')),
            DropdownMenuItem(value: 8000, child: Text('8,000 steps a day')),
            DropdownMenuItem(value: 10000, child: Text('10,000 steps a day')),
            DropdownMenuItem(value: 15000, child: Text('15,000 steps a day')),
          ],
          onChanged: (v) => setState(() => _target = v),
        ),
        const SizedBox(height: 12),
        const Text('Late uploads (e.g. a watch syncing the next morning) are counted until 48 hours after the '
            'challenge ends. After that the results are final.'),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _create, child: const Text('Create challenge')),
      ]),
    );
  }
}
