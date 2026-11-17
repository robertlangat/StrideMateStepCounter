import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../domain/day_key.dart';
import '../../widgets/common.dart';

class RestDaysScreen extends StatelessWidget {
  const RestDaysScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final today = startOfDay(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const Text('Rest Days')),
      body: ListenableBuilder(
        listenable: services.steps,
        builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Plan up to 2 Rest Days per week. They protect your streak, but don\'t extend it. '
              'Rest Days can\'t be added after the day has passed.'),
          const SizedBox(height: 12),
          for (var i = 0; i < 28; i++)
            Builder(builder: (context) {
              final d = addDays(today, i);
              final key = dayKey(d);
              final on = services.steps.restDays.contains(key);
              return CheckboxListTile(
                value: on,
                title: Text(i == 0 ? 'Today' : DateFormat.MMMMEEEEd().format(d)),
                onChanged: (v) async {
                  if (v == true) {
                    final problem = services.steps.canSetRestDay(key);
                    if (problem != null) {
                      showSnack(context, problem);
                      return;
                    }
                  }
                  await services.steps.setRestDay(key, v == true);
                  await services.sync?.syncNow();
                },
              );
            }),
        ]),
      ),
    );
  }
}
