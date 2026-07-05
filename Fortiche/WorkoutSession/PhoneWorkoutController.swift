import ActivityKit
import Foundation
import HealthKit
import Observation
import SwiftData
import UserNotifications
import FortichePack
import os

/// Runs a phone-authoritative workout (no watch involved): the engine lives
/// here, HealthKit recording goes through HKWorkoutBuilder (iPhone has no
/// HKWorkoutSession), the Live Activity is started from the foreground, and
/// rest alerts are delivered as local notifications (no workout background
/// mode on iOS).
@Observable @MainActor
final class PhoneWorkoutController {
    static let shared = PhoneWorkoutController()
    private static let logger = Logger(subsystem: "com.davidruiz.fortiche", category: "workout")

    private(set) var engine: ActiveWorkoutEngine?
    var isActive: Bool { engine != nil }

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var builder: HKWorkoutBuilder?
    @ObservationIgnored private var restTick: Task<Void, Never>?

    // MARK: Lifecycle

    func start(day: TemplateDay) async {
        guard engine == nil else { return }
        let state = WorkoutState.start(day: day, host: .phone)
        beginSession(with: state)

        // HealthKit recording (best effort — the workout proceeds even if
        // Health access is denied).
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = state.activityKind == .traditional
            ? .traditionalStrengthTraining : .functionalStrengthTraining
        configuration.locationType = .indoor
        // `--skip-health` keeps headless demo runs free of permission sheets.
        if !ProcessInfo.processInfo.arguments.contains("--skip-health") {
            let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
            do {
                try await healthStore.requestAuthorization(
                    toShare: [HKObjectType.workoutType()],
                    read: [HKQuantityType(.heartRate), HKQuantityType(.bodyMass)]
                )
                try await builder.beginCollection(at: state.startedAt)
                self.builder = builder
            } catch {
                Self.logger.info("HealthKit recording unavailable: \(error.localizedDescription, privacy: .public)")
            }

            await requestNotificationAuthorization()
        }
    }

    /// Restore an interrupted phone workout after an app kill/crash.
    func recoverIfNeeded() {
        guard engine == nil,
              let recovered = ActiveWorkoutEngine.recover(localHost: .phone),
              recovered.state.host == .phone
        else { return }
        Self.logger.info("recovered in-progress workout \(recovered.state.workoutUUID, privacy: .public)")
        beginSession(with: recovered.state, recovered: true)
    }

    func end(in modelContext: ModelContext) async {
        guard let engine else { return }
        engine.submit(.end)

        // Accidental starts (under the minimum duration) are discarded
        // entirely: no log, no HealthKit workout.
        let shouldSave = engine.state.qualifiesForSaving
        if shouldSave {
            // Persist the log (idempotent by workout UUID — a future
            // watch-side duplicate upserts over this).
            upsert(log: engine.state.makeLog(), in: modelContext)
        } else {
            Self.logger.info("discarding workout under minimum duration")
        }

        // Finish or discard the HealthKit recording to match.
        if let builder {
            do {
                if shouldSave {
                    for activity in engine.state.makeHealthKitActivities() {
                        try await builder.addWorkoutActivity(activity)
                    }
                    try await builder.endCollection(at: engine.state.endedAt ?? .now)
                    try await builder.finishWorkout()
                } else {
                    builder.discardWorkout()
                }
            } catch {
                Self.logger.error("HealthKit save failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        await endLiveActivity()
        cancelRestNotification()
        restTick?.cancel()
        builder = nil
        self.engine = nil
        ActiveWorkoutEngine.clearJournal()
    }

    // MARK: Internals

    private func beginSession(with state: WorkoutState, recovered: Bool = false) {
        let engine = ActiveWorkoutEngine(state: state, localHost: .phone)
        engine.onStateChange = { [weak self] state in
            self?.updateLiveActivity(with: state)
        }
        engine.onRestChange = { [weak self] deadline in
            self?.scheduleRestNotification(at: deadline)
        }
        self.engine = engine
        startLiveActivity(with: engine.state)
        startRestTicker()
        if recovered, let deadline = engine.restDeadline { scheduleRestNotification(at: deadline) }
    }

    private func startRestTicker() {
        restTick?.cancel()
        restTick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { self?.engine?.restExpired() }
            }
        }
    }

    private func upsert(log: WorkoutLog, in modelContext: ModelContext) {
        let uuid = log.uuid
        let existing = try? modelContext.fetch(
            FetchDescriptor<WorkoutLog>(predicate: #Predicate { $0.uuid == uuid })
        )
        existing?.forEach { modelContext.delete($0) }
        modelContext.insert(log)
        try? modelContext.save()
    }

    // MARK: Live Activity

    private func startLiveActivity(with state: WorkoutState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(
            attributes: WorkoutActivityAttributes(workoutTitle: state.title),
            content: ActivityContent(state: Self.contentState(for: state), staleDate: nil)
        )
    }

    private func updateLiveActivity(with state: WorkoutState) {
        let content = ActivityContent(state: Self.contentState(for: state), staleDate: nil as Date?)
        Task.detached {
            for activity in Activity<WorkoutActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    private func endLiveActivity() async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func contentState(for state: WorkoutState) -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(state: state, unit: .preferred)
    }

    // MARK: Rest notifications

    private func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private func scheduleRestNotification(at deadline: Date?) {
        cancelRestNotification()
        guard let deadline, deadline > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        content.body = "Time for your next set."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, deadline.timeIntervalSinceNow),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: "rest-timer", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelRestNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest-timer"])
    }
}
