#if canImport(ActivityKit) && !os(macOS)
import ActivityKit
import Foundation

/// Shared between the iOS app (which starts/updates the activity) and the
/// widget extension (which renders it on the lock screen, in the Dynamic
/// Island, and — automatically — in the watch Smart Stack).
public struct WorkoutActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var exerciseName: String
        /// 1-based current set and total for the current exercise.
        public var setNumber: Int
        public var setCount: Int
        /// "5 × 80 kg" style prescription for the current set.
        public var prescription: String
        /// Rest deadline when resting; nil while lifting.
        public var restUntil: Date?
        public var isPaused: Bool
        /// Overall workout progress 0…1 (completed sets / total sets).
        public var progress: Double

        public init(
            exerciseName: String,
            setNumber: Int,
            setCount: Int,
            prescription: String,
            restUntil: Date? = nil,
            isPaused: Bool = false,
            progress: Double = 0
        ) {
            self.exerciseName = exerciseName
            self.setNumber = setNumber
            self.setCount = setCount
            self.prescription = prescription
            self.restUntil = restUntil
            self.isPaused = isPaused
            self.progress = progress
        }
    }

    public var workoutTitle: String
    public init(workoutTitle: String) {
        self.workoutTitle = workoutTitle
    }
}

extension WorkoutActivityAttributes.ContentState {
    /// Build display state from engine state (single source of truth for both
    /// phone controllers).
    public init(state: WorkoutState, unit: WeightUnit) {
        let exerciseIndex = state.currentExercise?.isDone == false
            ? state.currentExerciseIndex
            : (state.exercises.firstIndex { !$0.isDone } ?? state.currentExerciseIndex)
        let exercise = state.exercises.indices.contains(exerciseIndex) ? state.exercises[exerciseIndex] : nil
        let setIndex = exercise?.currentSetIndex ?? 0
        let set = exercise.flatMap { $0.sets.indices.contains(setIndex) ? $0.sets[setIndex] : nil }

        var prescription = ""
        if let set {
            let reps = set.targetRepsMin == 0 ? "AMRAP"
                : set.targetRepsMax > set.targetRepsMin ? "\(set.targetRepsMin)–\(set.targetRepsMax)"
                : "\(set.targetRepsMax)"
            prescription = "\(reps) × \(set.weightKg.map { unit.format(kilograms: $0) } ?? "BW")"
        }

        var restUntil: Date?
        if case .resting(let until) = state.phase { restUntil = until }

        self.init(
            exerciseName: exercise?.name ?? "Workout",
            setNumber: setIndex + 1,
            setCount: exercise?.sets.count ?? 0,
            prescription: prescription,
            restUntil: restUntil,
            isPaused: state.phase == .paused,
            progress: state.totalSetCount > 0 ? Double(state.completedSetCount) / Double(state.totalSetCount) : 0
        )
    }
}
#endif
