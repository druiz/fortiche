import Foundation

// Wire representation of templates for WatchConnectivity transfer
// (the watch store never syncs via CloudKit; the phone pushes these).

/// Codable snapshot of a full `WorkoutTemplate` graph. Ordered nested arrays
/// replace the models' unordered CloudKit-style relationships; UUIDs are
/// preserved end-to-end so logs made on the watch still reference the right
/// template/day.
public struct TemplateDTO: Codable, Sendable {
    public var uuid: UUID
    public var name: String
    public var activityKindRaw: String
    public var days: [DayDTO]

    public struct DayDTO: Codable, Sendable {
        public var uuid: UUID
        public var name: String
        public var order: Int
        public var exercises: [ExerciseDTO]
    }

    public struct ExerciseDTO: Codable, Sendable {
        public var uuid: UUID
        public var name: String
        public var order: Int
        public var librarySlug: String?
        public var restSeconds: Int
        public var sets: [SetDTO]
    }

    public struct SetDTO: Codable, Sendable {
        public var uuid: UUID
        public var order: Int
        public var repsMin: Int
        public var repsMax: Int
        public var weightKg: Double?
        public var percentOfMax: Double?
        public var rpe: Double?
    }

    /// Flatten a SwiftData template into the wire form (phone side, pre-push).
    public init(_ template: WorkoutTemplate) {
        uuid = template.uuid
        name = template.name
        activityKindRaw = template.activityKindRaw
        days = template.orderedDays.map { day in
            DayDTO(
                uuid: day.uuid,
                name: day.name,
                order: day.order,
                exercises: day.orderedExercises.map { exercise in
                    ExerciseDTO(
                        uuid: exercise.uuid,
                        name: exercise.name,
                        order: exercise.order,
                        librarySlug: exercise.librarySlug,
                        restSeconds: exercise.restSeconds,
                        sets: exercise.orderedSets.map { set in
                            SetDTO(
                                uuid: set.uuid,
                                order: set.order,
                                repsMin: set.repsMin,
                                repsMax: set.repsMax,
                                weightKg: set.weightKg,
                                percentOfMax: set.percentOfMax,
                                rpe: set.rpe
                            )
                        }
                    )
                }
            )
        }
    }

    /// Rebuild a full template graph (used on the watch after transfer).
    public func makeTemplate() -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name)
        template.uuid = uuid
        template.activityKindRaw = activityKindRaw
        template.days = days.map { day in
            let templateDay = TemplateDay(name: day.name, order: day.order)
            templateDay.uuid = day.uuid
            templateDay.exercises = day.exercises.map { exercise in
                let templateExercise = TemplateExercise(
                    name: exercise.name,
                    order: exercise.order,
                    librarySlug: exercise.librarySlug,
                    restSeconds: exercise.restSeconds
                )
                templateExercise.uuid = exercise.uuid
                templateExercise.sets = exercise.sets.map { set in
                    let templateSet = TemplateSet(order: set.order, repsMin: set.repsMin, repsMax: set.repsMax, weightKg: set.weightKg)
                    templateSet.uuid = set.uuid
                    templateSet.percentOfMax = set.percentOfMax
                    templateSet.rpe = set.rpe
                    return templateSet
                }
                return templateExercise
            }
            return templateDay
        }
        return template
    }
}

/// Finished-workout payload sent watch → phone (dual-channel: mirrored session
/// and WC transferUserInfo; the phone upserts by workoutUUID so duplicates merge).
public struct FinishedWorkoutDTO: Codable, Sendable {
    public var state: WorkoutState

    public init(state: WorkoutState) {
        self.state = state
    }
}
