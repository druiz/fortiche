import ActivityKit
import FortichePack
import SwiftUI
import WidgetKit

@main
struct ForticheWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextWorkoutWidget()
        WorkoutLiveActivity()
    }
}

/// Live workout surface: lock screen, Dynamic Island, and (automatically)
/// the watch Smart Stack. Spike content for now; real set/rest state in M4.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            HStack {
                Image(systemName: "figure.strengthtraining.traditional")
                VStack(alignment: .leading) {
                    Text(context.attributes.workoutTitle).font(.headline)
                    Text(context.state.statusText).font(.caption)
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "figure.strengthtraining.traditional")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.workoutTitle).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.statusText).font(.caption)
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional")
            } compactTrailing: {
                Text("●").foregroundStyle(.green)
            } minimal: {
                Image(systemName: "figure.strengthtraining.traditional")
            }
        }
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
