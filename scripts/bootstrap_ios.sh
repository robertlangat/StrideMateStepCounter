#!/usr/bin/env bash
# Generates the Xcode project around the committed iOS sources (macOS + Xcode + Flutter).
# `flutter create` only adds files that are missing; it does not overwrite
# AppDelegate.swift, Info.plist, entitlements or the Podfile committed here.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter create --platforms=ios --org com.stridemate --project-name stridemate .
dart run flutter_launcher_icons
flutter pub get
(cd ios && pod install)
cat <<'MSG'

iOS project generated. Remaining one-time steps in Xcode (open ios/Runner.xcworkspace):
 1. Runner target › Signing & Capabilities: choose your Team; set bundle id com.stridemate.app.
 2. Add capabilities: HealthKit, App Groups (group.com.stridemate.app).
    Point CODE_SIGN_ENTITLEMENTS at Runner/Runner.entitlements.
 3. File › New › Target › Widget Extension named "StrideMateWidget" (no Live Activity,
    no configuration intent). Replace its generated Swift file with
    ios/StrideMateWidget/StrideMateWidget.swift, add App Groups capability
    (group.com.stridemate.app) using StrideMateWidget.entitlements.
 4. flutter run   (HealthKit and Core Motion need a physical iPhone.)
MSG
