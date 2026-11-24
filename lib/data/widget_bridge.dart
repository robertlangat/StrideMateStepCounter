import 'dart:io';

import 'package:home_widget/home_widget.dart';

import '../domain/day_key.dart';

/// Pushes the latest de-duplicated total to the home-screen widget.
class WidgetBridge {
  static const iosAppGroup = 'group.com.stridemate.app';

  static Future<void> init() async {
    if (Platform.isIOS) await HomeWidget.setAppGroupId(iosAppGroup);
  }

  static Future<void> push({required int steps, required int goal, required DateTime updated}) async {
    try {
      await HomeWidget.saveWidgetData<int>('steps', steps);
      await HomeWidget.saveWidgetData<int>('goal', goal);
      await HomeWidget.saveWidgetData<String>('day', dayKey(updated));
      await HomeWidget.saveWidgetData<int>('updated_ms', updated.millisecondsSinceEpoch);
      await HomeWidget.updateWidget(
        androidName: 'StepWidgetProvider',
        qualifiedAndroidName: 'com.stridemate.app.widget.StepWidgetProvider',
        iOSName: 'StrideMateWidget',
      );
    } catch (_) {
      // Widget extension not installed (e.g. iOS before the Xcode target is added).
    }
  }
}
