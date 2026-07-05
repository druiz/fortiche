import Foundation

/// Complete state of an in-progress workout. Value type, Codable:
/// - journaled to disk on every mutation (crash recovery)
/// - shipped whole as the snapshot in watch↔phone resync
public struct WorkoutState: Codable, Sendable, Equatable {
    public enum Phase: Codable, Sendable, Equatable {
        case active
        /// Rest timer running until the deadline (wall clock, survives relaunch).
        case resting(until: Date)
        case paused
        case ended
    }

    public var workoutUUID: UUID
    public var title: String
    public var host: WorkoutHost
    public var templateUUID: UUID?
    public var dayUUID: UUID?
    public var activityKind: StrengthActivityKind
    public var startedAt: Date
    public var endedAt: Date?
    public var phase: Phase
    public var exercises: [ExerciseState]
    public var currentExerciseIndex: Int
    /// Highest command sequence number applied per origin — the reconciliation
    /// cursor for optimistic remote edits.
    public var lastAppliedSeq: [WorkoutHost.RawValue: Int]

    public init(
        workoutUUID: UUID = UUID(),
        title: String,
        host: WorkoutHost,
        templateUUID: UUID? = nil,
        dayUUID: UUID? = nil,
        activityKind: StrengthActivityKind = .functional,
        startedAt: Date,
        exercises: [ExerciseState]
    ) {
        self.workoutUUID = workoutUUID
        self.title = title
        self.host = host
        self.templateUUID = templateUUID
        self.dayUUID = dayUUID
        self.activityKind = activityKind
        self.startedAt = startedAt
        self.phase = .active
        self.exercises = exercises
        self.currentExerciseIndex = 0
        self.lastAppliedSeq = [:]
    }

    public var currentExercise: ExerciseState? {
        exercises.indices.contains(currentExerciseIndex) ? exercises[currentExerciseIndex] : nil
    }

    public var isFinished: Bool { phase == .ended }

    /// Workouts shorter than this are treated as accidental starts and are
    /// discarded rather than saved (no log, no HealthKit sample).
    public static let minimumSaveDuration: TimeInterval = 3 * 60

    /// Whether this workout ran long enough to be worth keeping.
    public var qualifiesForSaving: Bool {
        (endedAt ?? .now).timeIntervalSince(startedAt) >= Self.minimumSaveDuration
    }

    /// Overall progress across all planned sets (for progress rings).
    public var completedSetCount: Int { exercises.flatMap(\.sets).count { $0.completedAt != nil } }
    public var totalSetCount: Int { exercises.flatMap(\.sets).count }
}

public struct ExerciseState: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var librarySlug: String?
    public var restSeconds: Int
    public var sets: [SetState]
    public var skipped: Bool

    public init(id: UUID = UUID(), name: String, librarySlug: String? = nil, restSeconds: Int = 90, sets: [SetState], skipped: Bool = false) {
        self.id = id
        self.name = name
        self.librarySlug = librarySlug
        self.restSeconds = restSeconds
        self.sets = sets
        self.skipped = skipped
    }

    public var currentSetIndex: Int? {
        sets.firstIndex { $0.completedAt == nil && !$0.skipped }
    }

    public var isDone: Bool { skipped || sets.allSatisfy { $0.completedAt != nil || $0.skipped } }
}

public struct SetState: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var targetRepsMin: Int
    public var targetRepsMax: Int
    /// Working weight for this set (kg). Pre-resolved from the template
    /// (absolute weight or %1RM × known max); editable mid-workout.
    public var weightKg: Double?
    public var targetRpe: Double?
    /// Filled when completed.
    public var actualReps: Int?
    public var completedAt: Date?
    public var skipped: Bool

    public init(
        id: UUID = UUID(),
        targetRepsMin: Int,
        targetRepsMax: Int? = nil,
        weightKg: Double? = nil,
        targetRpe: Double? = nil
    ) {
        self.id = id
        self.targetRepsMin = targetRepsMin
        self.targetRepsMax = targetRepsMax ?? targetRepsMin
        self.weightKg = weightKg
        self.targetRpe = targetRpe
        self.actualReps = nil
        self.completedAt = nil
        self.skipped = false
    }
}

extension WorkoutState {
    /// Build the initial state from a template day.
    public static func start(
        day: TemplateDay,
        host: WorkoutHost,
        bodyMassKg: Double? = nil,
        oneRepMaxes: [String: Double] = [:],
        now: Date = .now
    ) -> WorkoutState {
        let template = day.template
        let exercises = day.orderedExercises.map { exercise in
            ExerciseState(
                name: exercise.name,
                librarySlug: exercise.librarySlug,
                restSeconds: exercise.restSeconds,
                sets: exercise.orderedSets.map { set in
                    var weight = set.weightKg
                    if weight == nil, let percent = set.percentOfMax,
                       let max = exercise.librarySlug.flatMap({ oneRepMaxes[$0] }) {
                        weight = max * percent / 100
                    }
                    return SetState(
                        targetRepsMin: set.repsMin,
                        targetRepsMax: set.repsMax,
                        weightKg: weight,
                        targetRpe: set.rpe
                    )
                }
            )
        }
        return WorkoutState(
            title: [template?.name, day.name].compactMap(\.self).joined(separator: " — "),
            host: host,
            templateUUID: template?.uuid,
            dayUUID: day.uuid,
            activityKind: template?.activityKind ?? .functional,
            startedAt: now,
            exercises: exercises
        )
    }

    /// Materialize the finished workout for persistence/HealthKit.
    public func makeLog() -> WorkoutLog {
        let log = WorkoutLog(uuid: workoutUUID, title: title, startedAt: startedAt, host: host)
        log.endedAt = endedAt
        log.templateUUID = templateUUID
        log.dayUUID = dayUUID
        log.exercises = exercises.enumerated().compactMap { exerciseIndex, exercise in
            let completedSets = exercise.sets.filter { $0.completedAt != nil }
            guard !completedSets.isEmpty else { return nil }
            let logged = LoggedExercise(name: exercise.name, order: exerciseIndex, librarySlug: exercise.librarySlug)
            logged.sets = completedSets.enumerated().map { setIndex, set in
                let loggedSet = LoggedSet(order: setIndex, reps: set.actualReps ?? 0, weightKg: set.weightKg)
                loggedSet.completedAt = set.completedAt
                return loggedSet
            }
            return logged
        }
        return log
    }
}
