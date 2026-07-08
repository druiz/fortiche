import Foundation
import HealthKit
import SwiftData
import FortichePack
import os

/// Persists retroactive "mini workouts" (Quick Log) and exports them to
/// HealthKit. There is no live session: the state arrives pre-completed from
/// `WorkoutState.quickEntry`, so the sub-3-minute accidental-start rule does
/// not apply here.
@MainActor
final class QuickLogController {
    static let shared = QuickLogController()
    private static let logger = Logger(subsystem: "com.davidruiz.fortiche", category: "quicklog")

    private let healthStore = HKHealthStore()

    /// Saves the log locally (source of truth) and best-effort exports to
    /// HealthKit with the same one-activity-per-exercise shape as sessions.
    @discardableResult
    func save(state: WorkoutState, in context: ModelContext) async -> WorkoutLog {
        let log = state.makeLog()
        context.insert(log)
        try? context.save()

        guard HKHealthStore.isHealthDataAvailable(),
              !ProcessInfo.processInfo.arguments.contains("--skip-health") else { return log }
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()], read: []
            )
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = state.activityKind == .traditional
                ? .traditionalStrengthTraining
                : .functionalStrengthTraining
            configuration.locationType = .unknown
            let builder = HKWorkoutBuilder(
                healthStore: healthStore, configuration: configuration, device: .local()
            )
            try await builder.beginCollection(at: state.startedAt)
            for activity in state.makeHealthKitActivities() {
                try await builder.addWorkoutActivity(activity)
            }
            try await builder.endCollection(at: state.endedAt ?? .now)
            try await builder.finishWorkout()
        } catch {
            // Local log already saved; Health export failing is non-fatal
            // (e.g. authorization declined).
            Self.logger.warning("HealthKit export failed: \(error.localizedDescription, privacy: .public)")
        }
        return log
    }
}
