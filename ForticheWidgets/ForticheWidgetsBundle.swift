import SwiftUI
import WidgetKit

@main
struct ForticheWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextWorkoutWidget()
        // The workout Live Activity joins this bundle in M3/M4.
    }
}

/// Placeholder Home Screen widget so the extension target is functional from
/// day one; gains real "next scheduled day" content in M5.
struct NextWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextWorkoutWidget", provider: NextWorkoutProvider()) { entry in
            VStack {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title)
                Text("Fortiche")
                    .font(.caption)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Workout")
        .description("Your next scheduled training day.")
        .supportedFamilies([.systemSmall])
    }
}

struct NextWorkoutEntry: TimelineEntry {
    let date: Date
}

struct NextWorkoutProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextWorkoutEntry {
        NextWorkoutEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextWorkoutEntry) -> Void) {
        completion(NextWorkoutEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextWorkoutEntry>) -> Void) {
        completion(Timeline(entries: [NextWorkoutEntry(date: .now)], policy: .never))
    }
}
