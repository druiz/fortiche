import ActivityKit
import Foundation
import HealthKit
import Observation
import SwiftData
import FortichePack
import os

/// Phone-side client for a watch-authoritative workout.
///
/// Receives the mirrored `HKWorkoutSession`, runs a *peer* engine (optimistic
/// local application of edits, reconciled against watch snapshots), starts the
/// Live Activity inside the mirroring handler's background-launch window, and
/// ingests finished workouts arriving over either channel.
///
/// `install()` must run synchronously in the App initializer — the system
/// launches the app in the background when the watch starts mirroring, and a
/// lazily installed handler silently drops the session.
@Observable @MainActor
final class MirroringReceiver: NSObject {
    static let shared = MirroringReceiver()

    private static let logger = Logger(subsystem: "com.davidruiz.fortiche", category: "mirroring")

    @ObservationIgnored let healthStore = HKHealthStore()
    private(set) var engine: ActiveWorkoutEngine?
    var isActive: Bool { engine != nil }

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored var modelContainer: ModelContainer?

    // MARK: Install (synchronously at launch)

    nonisolated func install() {
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in
                self?.attach(to: session)
            }
        }
        ConnectivityHub.shared.activate()
        ConnectivityHub.shared.onLiveMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        ConnectivityHub.shared.onFinishedWorkoutReceived = { [weak self] finished in
            Task { @MainActor in self?.ingest(finished: finished.state) }
        }
        ConnectivityHub.shared.onReachabilityChange = { [weak self] reachable in
            guard reachable else { return }
            // Ask for current state after any connection blip — cheap and
            // idempotent; also how the phone discovers an in-flight workout.
            Task { @MainActor in self?.send(.requestSnapshot) }
        }
    }

    // MARK: Mirrored session lifecycle

    private func attach(to session: HKWorkoutSession) {
        self.session = session
        session.delegate = self
        Self.logger.info("mirrored session received")

        // Live Activity must start inside the ~10s background-launch window,
        // with placeholder content — the first snapshot fills it in.
        startLiveActivity(title: "Workout")
        send(.requestSnapshot)
    }

    private func handle(_ message: SyncMessage) {
        switch message {
        case .snapshot(let state):
            adopt(state)
        case .command, .requestSnapshot:
            break // peer side only consumes snapshots
        }
    }

    private func adopt(_ state: WorkoutState) {
        if state.isFinished {
            ingest(finished: state)
            teardown()
            return
        }
        if let engine {
            if !engine.adopt(snapshot: state) {
                Self.logger.info("ignored stale snapshot")
            }
        } else {
            let engine = ActiveWorkoutEngine(state: state, localHost: .phone, journalURL: nil)
            engine.onLocalCommand = { [weak self] envelope in
                self?.send(.command(envelope))
            }
            engine.onStateChange = { [weak self] state in
                self?.updateLiveActivity(with: state)
            }
            self.engine = engine
            updateLiveActivity(with: state)
        }
    }

    private func teardown() {
        Task { await endLiveActivity() }
        engine = nil
        session = nil
    }

    // MARK: Finished workouts (either channel; idempotent by UUID)

    private func ingest(finished state: WorkoutState) {
        // Same rule as the hosts: accidental sub-minimum workouts are dropped.
        guard state.qualifiesForSaving else {
            Self.logger.info("ignoring finished workout under minimum duration")
            return
        }
        guard let context = modelContainer.map({ ModelContext($0) }) else { return }
        let log = state.makeLog()
        let uuid = log.uuid
        let existing = (try? context.fetch(FetchDescriptor<WorkoutLog>(predicate: #Predicate { $0.uuid == uuid }))) ?? []
        existing.forEach { context.delete($0) }
        context.insert(log)
        try? context.save()
        Self.logger.info("ingested finished workout \(uuid, privacy: .public)")
    }

    // MARK: Sending

    private func send(_ message: SyncMessage) {
        if let session, let data = try? message.encoded() {
            session.sendToRemoteWorkoutSession(data: data) { _, _ in }
        }
        ConnectivityHub.shared.sendLive(message)
    }

    // MARK: Live Activity

    private func startLiveActivity(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard Activity<WorkoutActivityAttributes>.activities.isEmpty else { return }
        _ = try? Activity.request(
            attributes: WorkoutActivityAttributes(workoutTitle: title),
            content: ActivityContent(
                state: WorkoutActivityAttributes.ContentState(
                    exerciseName: "Connecting to watch…",
                    setNumber: 1,
                    setCount: 0,
                    prescription: ""
                ),
                staleDate: nil
            )
        )
    }

    private func updateLiveActivity(with state: WorkoutState) {
        let content = ActivityContent(
            state: WorkoutActivityAttributes.ContentState(state: state, unit: .preferred),
            staleDate: nil as Date?
        )
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

    // MARK: Health authorization (mirrored delivery requires it)

    func requestAuthorization() async {
        _ = try? await healthStore.requestAuthorization(
            toShare: [HKObjectType.workoutType()],
            read: [HKQuantityType(.heartRate), HKQuantityType(.bodyMass)]
        )
    }
}

extension MirroringReceiver: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            Self.logger.error("mirrored session error: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in
            for item in data {
                if let message = try? SyncMessage.decode(item) { self.handle(message) }
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in
            Self.logger.info("watch disconnected: \(error?.localizedDescription ?? "clean", privacy: .public)")
            // Keep the engine (optimistic edits are rejected with UI feedback
            // while disconnected); a fresh snapshot re-syncs on reconnect.
            self.send(.requestSnapshot)
        }
    }
}
