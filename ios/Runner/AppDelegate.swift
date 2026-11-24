import CoreMotion
import Flutter
import UIKit

/// iOS step counting with Core Motion (CMPedometer). The motion coprocessor keeps
/// counting while the app is closed and stores 7 days of history, so the app
/// catches up whenever it is opened. HealthKit is read via the `health` plugin.
@main
@objc class AppDelegate: FlutterAppDelegate {
  private let pedometer = CMPedometer()
  private var channel: FlutterMethodChannel?
  private var initialLink: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = launchOptions?[.url] as? URL {
      initialLink = url.absoluteString
    }
    if let controller = window?.rootViewController as? FlutterViewController {
      let ch = FlutterMethodChannel(name: "stridemate/motion", binaryMessenger: controller.binaryMessenger)
      ch.setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
      channel = ch
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if url.scheme == "stridemate" {
      channel?.invokeMethod("onLink", arguments: url.absoluteString)
      return true
    }
    return super.application(app, open: url, options: options)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(CMPedometer.isStepCountingAvailable())
    case "authorizationStatus":
      result(statusName(CMPedometer.authorizationStatus()))
    case "requestAuthorization":
      // The first pedometer query shows the Motion & Fitness permission prompt.
      let now = Date()
      pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { [weak self] _, _ in
        DispatchQueue.main.async { result(self?.statusName(CMPedometer.authorizationStatus())) }
      }
    case "queryHourly":
      queryHourly(call.arguments as? [String: Any], result: result)
    case "getInitialLink":
      result(initialLink)
      initialLink = nil
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func statusName(_ s: CMAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }

  /// Hour-by-hour step totals between fromMs and toMs (clamped to the last 7 days).
  private func queryHourly(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard CMPedometer.isStepCountingAvailable() else { result([]); return }
    let now = Date()
    let fromMs = (args?["fromMs"] as? NSNumber)?.doubleValue ?? now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000
    let toMs = (args?["toMs"] as? NSNumber)?.doubleValue ?? now.timeIntervalSince1970 * 1000
    let earliest = now.addingTimeInterval(-7 * 86400 + 3600)
    var start = max(Date(timeIntervalSince1970: fromMs / 1000), earliest)
    start = Date(timeIntervalSince1970: ceil(start.timeIntervalSince1970 / 3600) * 3600)
    let end = min(Date(timeIntervalSince1970: toMs / 1000), now)

    var rows: [[String: Any]] = []
    let lock = NSLock()
    let group = DispatchGroup()
    var t = start
    while t < end {
      let hourStart = t
      let hourEnd = min(t.addingTimeInterval(3600), end)
      group.enter()
      pedometer.queryPedometerData(from: hourStart, to: hourEnd) { data, _ in
        if let steps = data?.numberOfSteps.intValue, steps > 0 {
          lock.lock()
          rows.append(["hour_ms": Int64(hourStart.timeIntervalSince1970 * 1000), "steps": steps])
          lock.unlock()
        }
        group.leave()
      }
      t = t.addingTimeInterval(3600)
    }
    group.notify(queue: .main) { result(rows) }
  }
}
