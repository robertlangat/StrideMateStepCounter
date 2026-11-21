import SwiftUI
import WidgetKit

/// Home-screen widget. Data is written by the app through the home_widget plugin
/// into the shared App Group "group.com.stridemate.app".
struct StepEntry: TimelineEntry {
  let date: Date
  let steps: Int
  let goal: Int
  let updated: Date?
}

struct StepProvider: TimelineProvider {
  private let defaults = UserDefaults(suiteName: "group.com.stridemate.app")

  private func read() -> StepEntry {
    let updatedMs = defaults?.object(forKey: "updated_ms") as? NSNumber
    let updated = updatedMs.map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    let day = defaults?.string(forKey: "day")
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let isToday = day == fmt.string(from: Date())
    return StepEntry(
      date: Date(),
      steps: isToday ? (defaults?.integer(forKey: "steps") ?? 0) : 0,
      goal: max(defaults?.integer(forKey: "goal") ?? 8000, 1),
      updated: updated)
  }

  func placeholder(in context: Context) -> StepEntry { StepEntry(date: Date(), steps: 6420, goal: 8000, updated: Date()) }
  func getSnapshot(in context: Context, completion: @escaping (StepEntry) -> Void) { completion(read()) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<StepEntry>) -> Void) {
    completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(30 * 60))))
  }
}

struct StrideMateWidgetView: View {
  let entry: StepEntry
  private let navy = Color(red: 10 / 255, green: 26 / 255, blue: 63 / 255)
  private let mint = Color(red: 108 / 255, green: 245 / 255, blue: 154 / 255)
  private let ivory = Color(red: 251 / 255, green: 246 / 255, blue: 238 / 255)

  var stale: Bool { entry.updated.map { Date().timeIntervalSince($0) > 2 * 3600 } ?? true }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("StrideMate").font(.caption).foregroundColor(mint)
      Text(entry.steps.formatted()).font(.system(size: 30, weight: .bold)).foregroundColor(ivory)
        .minimumScaleFactor(0.5)
      Text("of \(entry.goal.formatted())").font(.caption2).foregroundColor(ivory.opacity(0.8))
      ProgressView(value: min(Double(entry.steps), Double(entry.goal)), total: Double(entry.goal)).tint(mint)
      if let u = entry.updated {
        Text(stale ? "Last updated \(u.formatted(date: .omitted, time: .shortened))" : "Updated \(u.formatted(date: .omitted, time: .shortened))")
          .font(.caption2).foregroundColor(ivory.opacity(0.7))
      }
    }
    .padding()
    .accessibilityElement(children: .combine)
    .modifier(WidgetBackground(color: navy))
  }
}

struct WidgetBackground: ViewModifier {
  let color: Color
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(color, for: .widget)
    } else {
      content.background(color)
    }
  }
}

@main
struct StrideMateWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "StrideMateWidget", provider: StepProvider()) { entry in
      StrideMateWidgetView(entry: entry)
    }
    .configurationDisplayName("StrideMate steps")
    .description("Today's steps and goal progress.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
