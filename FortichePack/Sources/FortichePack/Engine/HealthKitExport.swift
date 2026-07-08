#if canImport(HealthKit) && !os(macOS)
import Foundation
import HealthKit

extension WorkoutState {
    /// Metadata key on each `HKWorkoutActivity` carrying that exercise's set
    /// details as a JSON string (HealthKit metadata values must be scalars).
    public static let exerciseMetadataKey = "com.davidruiz.fortiche.exercise"

    /// One `HKWorkoutActivity` per completed exercise, so the workout's
    /// structure is visible in Apple Health/Fitness. Set details ride along
    /// as JSON metadata.
    public func makeHealthKitActivities() -> [HKWorkoutActivity] {
        exercises.compactMap { exercise in
            let completed = exercise.sets.filter { $0.completedAt != nil }
            guard let firstCompletion = completed.compactMap(\.completedAt).min(),
                  let lastCompletion = completed.compactMap(\.completedAt).max()
            else { return nil }

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activityKind == .traditional
                ? .traditionalStrengthTraining : .functionalStrengthTraining
            configuration.locationType = .indoor

            var metadata: [String: Any] = [:]
            let payload: [String: Any] = [
                "name": exercise.name,
                "librarySlug": exercise.librarySlug as Any,
                "sets": completed.map { ["reps": $0.actualReps ?? 0, "weightKg": $0.weightKg ?? 0] },
            ]
            if let json = try? JSONSerialization.data(withJSONObject: payload),
               let string = String(data: json, encoding: .utf8) {
                metadata[Self.exerciseMetadataKey] = string
            }

            // Start the activity at the estimated beginning of the first set
            // (its completion minus a nominal set duration) for a sane timeline.
            let start = firstCompletion.addingTimeInterval(-45)
            return HKWorkoutActivity(
                workoutConfiguration: configuration,
                start: max(start, startedAt),
                end: lastCompletion,
                metadata: metadata
            )
        }
    }
}

#endif
