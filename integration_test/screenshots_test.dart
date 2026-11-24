// Captures Play Store screenshots on an emulator with sample data:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart \
//     --dart-define=DEMO_DATA=true --dart-define=ADS_ENABLED=false
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stridemate/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int seconds = 3]) async {
    for (var i = 0; i < seconds * 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
  }

  testWidgets('store screenshots', (tester) async {
    app.main();
    await settle(tester, 8);
    await binding.convertFlutterSurfaceToImage();
    await settle(tester, 2);
    await binding.takeScreenshot('01_today');

    await tester.tap(find.text('History').last);
    await settle(tester);
    await binding.takeScreenshot('02_history_week');

    await tester.tap(find.text('Month'));
    await settle(tester);
    await binding.takeScreenshot('03_history_month');

    await tester.tap(find.text('Year'));
    await settle(tester);
    await binding.takeScreenshot('04_history_year');

    await tester.tap(find.byTooltip('Achievements and records'));
    await settle(tester);
    await binding.takeScreenshot('05_achievements');
    await tester.pageBack();
    await settle(tester, 2);

    await tester.tap(find.byTooltip('Recaps'));
    await settle(tester);
    await binding.takeScreenshot('06_recap');
    await tester.pageBack();
    await settle(tester, 2);

    await tester.tap(find.text('Profile').last);
    await settle(tester);
    await binding.takeScreenshot('07_profile');
  });
}
