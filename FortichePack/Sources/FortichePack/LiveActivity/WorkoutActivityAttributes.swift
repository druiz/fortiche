#if canImport(ActivityKit)
import ActivityKit

/// Shared between the iOS app (which starts the activity from the mirroring
/// handler) and the widget extension (which renders it). Spike-level content
/// for now; gains real set/rep/rest state in M3/M4.
public struct WorkoutActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var statusText: String
        public init(statusText: String) {
            self.statusText = statusText
        }
    }

    public var workoutTitle: String
    public init(workoutTitle: String) {
        self.workoutTitle = workoutTitle
    }
}
#endif
