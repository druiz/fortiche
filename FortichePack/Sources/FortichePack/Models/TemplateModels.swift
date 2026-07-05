import Foundation
import SwiftData

// CloudKit-compatible SwiftData rules apply to every model in this file:
// all properties optional or defaulted, no #Unique/@Attribute(.unique),
// relationships optional with explicit inverses, explicit `order` keys
// because CloudKit relationships are unordered.

/// A saved training program: an ordered list of days, each a list of
/// prescribed exercises. Templates are the plan; `WorkoutLog` records the
/// actuals.
@Model
public final class WorkoutTemplate {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var notes: String?
    public var createdAt: Date = Date.distantPast
    /// Raw text the template was parsed from, kept for re-parsing/debugging.
    public var sourceText: String?
    /// HealthKit activity kind: see `StrengthActivityKind`.
    public var activityKindRaw: String = StrengthActivityKind.functional.rawValue

    @Relationship(deleteRule: .cascade, inverse: \TemplateDay.template)
    public var days: [TemplateDay]? = []

    public init(name: String, sourceText: String? = nil) {
        self.uuid = UUID()
        self.name = name
        self.sourceText = sourceText
        self.createdAt = Date()
    }

    public var activityKind: StrengthActivityKind {
        get { StrengthActivityKind(rawValue: activityKindRaw) ?? .functional }
        set { activityKindRaw = newValue.rawValue }
    }

    public var orderedDays: [TemplateDay] { (days ?? []).sorted { $0.order < $1.order } }
}

/// One training day within a program ("Push A", "Legs").
@Model
public final class TemplateDay {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var order: Int = 0
    public var template: WorkoutTemplate?

    @Relationship(deleteRule: .cascade, inverse: \TemplateExercise.day)
    public var exercises: [TemplateExercise]? = []

    public init(name: String, order: Int) {
        self.uuid = UUID()
        self.name = name
        self.order = order
    }

    public var orderedExercises: [TemplateExercise] { (exercises ?? []).sorted { $0.order < $1.order } }
}

/// An exercise prescription within a day: sets, rest, optional library match.
@Model
public final class TemplateExercise {
    public var uuid: UUID = UUID()
    public var order: Int = 0
    /// Display name as written in the program ("OHP", "Squat").
    public var name: String = ""
    /// Optional match into the bundled exercise library (`LibraryExercise.slug`).
    public var librarySlug: String?
    public var restSeconds: Int = 90
    public var notes: String?
    public var day: TemplateDay?

    @Relationship(deleteRule: .cascade, inverse: \TemplateSet.exercise)
    public var sets: [TemplateSet]? = []

    public init(name: String, order: Int, librarySlug: String? = nil, restSeconds: Int = 90) {
        self.uuid = UUID()
        self.name = name
        self.order = order
        self.librarySlug = librarySlug
        self.restSeconds = restSeconds
    }

    public var orderedSets: [TemplateSet] { (sets ?? []).sorted { $0.order < $1.order } }
}

/// One prescribed set: a rep target plus at most one load spec (absolute
/// weight, % of 1RM, or RPE).
@Model
public final class TemplateSet {
    public var uuid: UUID = UUID()
    public var order: Int = 0
    /// Target reps. `repsMax == repsMin` for a fixed target; 0/0 = open set (AMRAP or untargeted).
    public var repsMin: Int = 0
    public var repsMax: Int = 0
    /// Canonical kilograms. nil = bodyweight or unspecified.
    public var weightKg: Double?
    /// Alternative to absolute weight: percentage of estimated 1RM (0–100).
    public var percentOfMax: Double?
    public var rpe: Double?
    public var exercise: TemplateExercise?

    public init(order: Int, repsMin: Int = 0, repsMax: Int = 0, weightKg: Double? = nil) {
        self.uuid = UUID()
        self.order = order
        self.repsMin = repsMin
        self.repsMax = repsMax
        self.weightKg = weightKg
    }
}

/// How a program's workouts are classified when exported to HealthKit.
public enum StrengthActivityKind: String, Codable, Sendable, CaseIterable {
    /// Maps to `HKWorkoutActivityType.functionalStrengthTraining`.
    case functional
    /// Maps to `HKWorkoutActivityType.traditionalStrengthTraining`.
    case traditional
}
