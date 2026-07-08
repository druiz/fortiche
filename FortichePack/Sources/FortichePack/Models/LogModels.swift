import Foundation
import SwiftData

// Same CloudKit-compatible rules as TemplateModels.swift.

/// A finished workout as it was actually performed. Written once when the
/// session ends (sessions under 3 minutes are discarded and never logged).
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
    /// How this log came to be: a live session or a retroactive quick log.
    /// Defaulted for CloudKit compatibility and for records that predate it.
    public var kindRaw: String = WorkoutLogKind.session.rawValue
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

    public var kind: WorkoutLogKind {
        get { WorkoutLogKind(rawValue: kindRaw) ?? .session }
        set { kindRaw = newValue.rawValue }
    }

    public var orderedExercises: [LoggedExercise] { (exercises ?? []).sorted { $0.order < $1.order } }
}

/// One exercise within a log. `librarySlug` optionally ties it back to the
/// bundled exercise library so history matches across renamed free-form names.
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

/// A single performed set — actuals, not prescription.
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

/// Which device ran the authoritative engine for a session. The other device
/// (if any) runs a peer engine reconciled by sequence-numbered snapshots.
public enum WorkoutHost: String, Codable, Sendable {
    case phone
    case watch
}

extension WorkoutLog {
    // Pure derived metrics — kept out of HealthKitExport.swift so they exist
    // on every platform (including macOS test hosts).

    /// Total lifted volume in kg (Σ reps × weight).
    public var totalVolumeKg: Double {
        orderedExercises.flatMap(\.orderedSets).reduce(0) { total, set in
            total + Double(set.reps) * (set.weightKg ?? 0)
        }
    }

    /// Count of logged sets across all exercises.
    public var totalSets: Int {
        orderedExercises.reduce(0) { $0 + $1.orderedSets.count }
    }

    /// Wall-clock session length; nil until the workout has ended.
    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

/// How a `WorkoutLog` was produced.
public enum WorkoutLogKind: String, Codable, Sendable {
    /// A live tracked session (timer, rest, live sync).
    case session
    /// A retroactive "mini workout" logged after the fact (crunches in front
    /// of the TV). No live session ran, so session-only rules — like the
    /// sub-3-minute accidental-start discard — deliberately do not apply.
    case quick
}
