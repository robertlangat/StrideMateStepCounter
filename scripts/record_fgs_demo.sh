#!/usr/bin/env bash
# Records a screen video of the "Live counting" foreground service on a running
# emulator (emulator-5554). Output: fgs-demo.mp4. Used by .github/workflows/fgs-video.yml
set -u
PKG=com.stridemate.app
adb logcat -c
# Keep runtime permissions granted so no system dialog interrupts the demo.
( while true; do
    adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
    adb shell pm grant $PKG android.permission.ACTIVITY_RECOGNITION >/dev/null 2>&1
    sleep 1
  done ) &
GRANT=$!
(
  until adb logcat -d | grep -q "FGSDEMO:ready"; do sleep 1; done
  adb shell screenrecord --bit-rate 8000000 --time-limit 60 /sdcard/fgs-demo.mp4 &
  REC=$!
  until adb logcat -d | grep -q "FGSDEMO:enabled"; do sleep 1; done
  sleep 4
  adb shell cmd statusbar expand-notifications; sleep 9
  adb shell cmd statusbar collapse; sleep 2
  adb shell input keyevent KEYCODE_HOME; sleep 4
  adb shell cmd statusbar expand-notifications; sleep 15
  adb shell cmd statusbar collapse
  wait $REC
) &
ORCH=$!
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/fgs_demo_test.dart \
  -d emulator-5554 --dart-define=DEMO_DATA=true --dart-define=ADS_ENABLED=false > fgs.log 2>&1
echo "flutter drive exit: $?" >> fgs.log
for i in $(seq 1 60); do kill -0 $ORCH 2>/dev/null || break; sleep 2; done
kill $GRANT 2>/dev/null || true
sleep 2
adb pull /sdcard/fgs-demo.mp4 fgs-demo.mp4 >> fgs.log 2>&1 || true
ls -l fgs-demo.mp4 >> fgs.log 2>&1 || true
exit 0
