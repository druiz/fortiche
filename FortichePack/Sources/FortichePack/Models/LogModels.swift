import Foundation
import SwiftData

// Same CloudKit-compatible rules as TemplateModels.swift.

@Model
public final class WorkoutLog {
    /// Stable identity used for idempotent upserts — a finished workout may arrive
    /// on the phone via both the mirrored session channel and WatchConnectivity.
    public var uuid: UUID = UUID()
    public var title: String = ""
    public var startedAt: Date = Date.distantPast
    public var endedAt: Date?
    public var templateUUID: UUID?
    public var dayUUID: UUID?
    /// Which device ran the authoritative engine: see `WorkoutHost`.
    public var hostRaw: String = WorkoutHost.phone.rawValue
    public var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \LoggedExercise.log)
    public var exercises: [LoggedExercise]? = []

    public init(uuid: UUID = UUID(), title: String, startedAt: Date, host: WorkoutHost) {
        self.uuid = uuid
        self.title = title
        self.startedAt = startedAt
        self.hostRaw = host.rawValue
    }

    public var host: WorkoutHost {
        get { WorkoutHost(rawValue: hostRaw) ?? .phone }
        set { hostRaw = newValue.rawValue }
    }

    public var orderedExercises: [LoggedExercise] { (exercises ?? []).sorted { $0.order < $1.order } }
}

@Model
public final class LoggedExercise {
    public var uuid: UUID = UUID()
    public var order: Int = 0
    public var name: String = ""
    public var librarySlug: String?
    public var log: WorkoutLog?

    @Relationship(deleteRule: .cascade, inverse: \LoggedSet.exercise)
    public var sets: [LoggedSet]? = []

    public init(name: String, order: Int, librarySlug: String? = nil) {
        self.uuid = UUID()
        self.name = name
        self.order = order
        self.librarySlug = librarySlug
    }

    public var orderedSets: [LoggedSet] { (sets ?? []).sorted { $0.order < $1.order } }
}

@Model
public final class LoggedSet {
    public var uuid: UUID = UUID()
    public var order: Int = 0
    public var reps: Int = 0
    /// Canonical kilograms. nil = bodyweight.
    public var weightKg: Double?
    public var rpe: Double?
    public var completedAt: Date?
    public var skipped: Bool = false
    public var exercise: LoggedExercise?

    public init(order: Int, reps: Int = 0, weightKg: Double? = nil) {
        self.uuid = UUID()
        self.order = order
        self.reps = reps
        self.weightKg = weightKg
    }
}

public enum WorkoutHost: String, Codable, Sendable {
    case phone
    case watch
}
