import ActivityKit
import FortichePack
import SwiftUI
import WidgetKit

/// Widget-extension entry point: the Home Screen widget and the live-workout
/// activity.
@main
struct ForticheWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextWorkoutWidget()
        WorkoutLiveActivity()
    }
}

/// Live workout surface: lock screen, Dynamic Island, and (automatically)
/// the watch Smart Stack.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenWorkoutView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.exerciseName).font(.headline).lineLimit(1)
                        statusLine(context.state).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let until = context.state.restUntil {
                        Text(timerInterval: Date.now...until, countsDown: true)
                            .font(.title3.bold().monospacedDigit())
                            .frame(width: 60)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    controls(context.state)
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional")
            } compactTrailing: {
                if let until = context.state.restUntil {
                    Text(timerInterval: Date.now...until, countsDown: true)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                } else {
                    Text("\(context.state.setNumber)/\(context.state.setCount)")
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: context.state.restUntil != nil ? "timer" : "figure.strengthtraining.traditional")
            }
        }
    }

    /// One-line phase summary for the expanded island.
    @ViewBuilder
    private func statusLine(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        if state.isPaused {
            Text("Paused")
        } else if state.restUntil != nil {
            Text("Resting · next: set \(state.setNumber) of \(state.setCount)")
        } else {
            Text("Set \(state.setNumber) of \(state.setCount) · \(state.prescription)")
        }
    }

    /// Pause/resume plus one contextual primary action: skip rest while
    /// resting, complete the set otherwise. Buttons fire App Intents against
    /// the running engine — no app foregrounding needed.
    @ViewBuilder
    private func controls(_ state: WorkoutActivityAttributes.ContentState) -> some View {
        HStack {
            Button(intent: PauseResumeIntent()) {
                Label(state.isPaused ? "Resume" : "Pause", systemImage: state.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            if state.restUntil != nil {
                Button(intent: SkipRestIntent()) {
                    Label("Skip Rest", systemImage: "forward.fill")
                }
                .buttonStyle(.borderedProminent)
            } else if !state.isPaused, state.setCount > 0 {
                Button(intent: CompleteSetIntent()) {
                    Label("Done Set", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }
}

/// Lock-screen face of the Live Activity: rest countdown or the current-set
/// prescription, plus the same interactive controls as the Dynamic Island.
struct LockScreenWorkoutView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "figure.strengthtraining.traditional")
                Text(context.attributes.workoutTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ProgressView(value: context.state.progress)
                    .frame(width: 60)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    if context.state.restUntil != nil {
                        Text("Resting").font(.headline)
                        // The current pointer already advanced — this IS the next set.
                        Text("Next: \(context.state.exerciseName) · set \(context.state.setNumber) of \(context.state.setCount) · \(context.state.prescription)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(context.state.exerciseName).font(.headline).lineLimit(1)
                        if context.state.isPaused {
                            Text("Paused").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Set \(context.state.setNumber) of \(context.state.setCount) · \(context.state.prescription)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if let until = context.state.restUntil {
                    Text(timerInterval: Date.now...until, countsDown: true)
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .frame(maxWidth: 110)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.tint)
                }
            }
            HStack {
                Button(intent: PauseResumeIntent()) {
                    Label(context.state.isPaused ? "Resume" : "Pause", systemImage: context.state.isPaused ? "play.fill" : "pause.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                if context.state.restUntil != nil {
                    Button(intent: SkipRestIntent()) {
                        Label("Skip Rest", systemImage: "forward.fill").font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                } else if !context.state.isPaused, context.state.setCount > 0 {
                    Button(intent: CompleteSetIntent()) {
                        Label("Done — \(context.state.prescription)", systemImage: "checkmark")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                Spacer()
            }
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.55))
        .activitySystemActionForegroundColor(.white)
    }
}

/// Placeholder Home Screen widget (real "next scheduled day" content in M5).
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

/// Static single-entry timeline — the placeholder widget has no dynamic
/// content to refresh yet.
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
