// Records the Play Console foreground-service demo (see scripts/record_fgs_demo.sh).
// The emulator has no step sensor, so walking is simulated with the debug-only
// "demoFeed" hook; the setting, service and notification are the real app.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stridemate/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('stridemate/steps');

  Future<void> wait(WidgetTester tester, double seconds) async {
    for (var i = 0; i < (seconds * 4).round(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
  }

  testWidgets('live counting foreground service demo', (tester) async {
    app.main();
    for (var i = 0; i < 120 && find.text('Profile').evaluate().isEmpty; i++) {
      await wait(tester, 1);
    }
    await wait(tester, 3);
    await tester.tap(find.text('Profile').last);
    await wait(tester, 2);
    await tester.ensureVisible(find.text('Step sources'));
    await tester.tap(find.text('Step sources'));
    await wait(tester, 3);
    debugPrint('FGSDEMO:ready');
    await wait(tester, 5);
    await tester.tap(find.text('Live counting notification'));
    await wait(tester, 3);
    debugPrint('FGSDEMO:enabled');
    // Simulated walking for ~70 s (no pumping: the app goes to the background).
    for (var i = 0; i < 70; i++) {
      await channel.invokeMethod('demoFeed', {'steps': 20 + (i % 5) * 4});
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  });
}
