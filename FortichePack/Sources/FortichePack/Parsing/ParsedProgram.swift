import Foundation

// Parser output model — also the editable model behind the import review UI.
// Deliberately plain values (no SwiftData) so it works on any actor and in tests;
// converted to the @Model graph only on save.

public struct ParsedProgram: Sendable, Equatable {
    public var name: String
    public var days: [ParsedDay]
    /// True when at least one day came from the heuristic fallback rather
    /// than the language model (surfaced in the review UI).
    public var usedFallback: Bool

    public init(name: String, days: [ParsedDay], usedFallback: Bool = false) {
        self.name = name
        self.days = days
        self.usedFallback = usedFallback
    }
}

public struct ParsedDay: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var exercises: [ParsedExercise]

    public init(name: String, exercises: [ParsedExercise]) {
        self.name = name
        self.exercises = exercises
    }
}

public struct ParsedExercise: Sendable, Equatable, Identifiable {
    public var id = UUID()
    /// Name as written in the program.
    public var name: String
    /// Optional match into `ExerciseLibrary` (best-effort, user-overridable).
    public var librarySlug: String?
    public var restSeconds: Int?
    public var sets: [ParsedSet]

    public init(name: String, librarySlug: String? = nil, restSeconds: Int? = nil, sets: [ParsedSet]) {
        self.name = name
        self.librarySlug = librarySlug
        self.restSeconds = restSeconds
        self.sets = sets
    }
}

public struct ParsedSet: Sendable, Equatable, Identifiable {
    public var id = UUID()
    /// Target reps; 0 means open/AMRAP.
    public var repsMin: Int
    public var repsMax: Int
    /// Canonical kilograms (converted at parse time). nil = bodyweight/unspecified.
    public var weightKg: Double?
    /// Alternative to absolute weight (0–100).
    public var percentOfMax: Double?
    public var rpe: Double?

    public init(repsMin: Int, repsMax: Int? = nil, weightKg: Double? = nil, percentOfMax: Double? = nil, rpe: Double? = nil) {
        self.repsMin = repsMin
        self.repsMax = repsMax ?? repsMin
        self.weightKg = weightKg
        self.percentOfMax = percentOfMax
        self.rpe = rpe
    }
}

extension ParsedProgram {
    /// Materialize into the SwiftData model graph (insert the result into a context).
    public func makeTemplate(sourceText: String?) -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name, sourceText: sourceText)
        template.days = days.enumerated().map { dayIndex, day in
            let templateDay = TemplateDay(name: day.name, order: dayIndex)
            templateDay.exercises = day.exercises.enumerated().map { exerciseIndex, exercise in
                let templateExercise = TemplateExercise(
                    name: exercise.name,
                    order: exerciseIndex,
                    librarySlug: exercise.librarySlug,
                    restSeconds: exercise.restSeconds ?? 90
                )
                templateExercise.sets = exercise.sets.enumerated().map { setIndex, set in
                    let templateSet = TemplateSet(
                        order: setIndex,
                        repsMin: set.repsMin,
                        repsMax: set.repsMax,
                        weightKg: set.weightKg
                    )
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
