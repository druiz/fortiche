import ActivityKit
import Foundation
import HealthKit
import FortichePack
import os

/// Receives the workout session mirrored from the watch.
///
/// The system launches this app in the *background* when the watch calls
/// `startMirroringToCompanionDevice` and delivers the session immediately —
/// so `install()` must run synchronously in `ForticheApp.init`, and the Live
/// Activity must be requested inside the handler (≈10s window after the
/// background launch).
@MainActor
final class MirroringReceiver: NSObject, ObservableObject {
    static let shared = MirroringReceiver()

    private static let logger = Logger(subsystem: "com.davidruiz.fortiche", category: "mirroring")

    let healthStore = HKHealthStore()
    @Published private(set) var events: [String] = []
    @Published private(set) var sessionState: HKWorkoutSessionState?

    private var session: HKWorkoutSession?

    /// Must be called synchronously from the App initializer.
    nonisolated func install() {
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in
                self?.attach(to: session)
            }
        }
    }

    /// Mirrored-session delivery requires this app to hold workout
    /// authorization of its own; request it up front.
    func requestAuthorization() async {
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
            )
            log("health authorized")
        } catch {
            log("health auth failed: \(error.localizedDescription)")
        }
    }

    private func attach(to session: HKWorkoutSession) {
        self.session = session
        session.delegate = self
        log("mirrored session received (state \(session.state.rawValue))")

        startLiveActivity()

        // Round-trip probe: watch echoes anything it receives.
        send("ping-from-phone")
    }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log("live activities disabled — continuing without")
            return
        }
        do {
            _ = try Activity.request(
                attributes: WorkoutActivityAttributes(workoutTitle: "Spike Workout"),
                content: ActivityContent(
                    state: WorkoutActivityAttributes.ContentState(statusText: "Connecting…"),
                    staleDate: nil
                )
            )
            log("live activity started")
        } catch {
            log("live activity failed: \(error.localizedDescription)")
        }
    }

    private func send(_ message: String) {
        guard let session else { return }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: Data(message.utf8))
                await self.log("sent: \(message)")
            } catch {
                await self.log("send failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateActivity(_ text: String) {
        // Activity isn't Sendable, so look it up inside the task's own region
        // instead of holding a reference across actors.
        let content = ActivityContent(
            state: WorkoutActivityAttributes.ContentState(statusText: text),
            staleDate: nil as Date?
        )
        Task.detached {
            for activity in Activity<WorkoutActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    private func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        events.append(message)
    }
}

extension MirroringReceiver: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            sessionState = toState
            log("state \(fromState.rawValue) → \(toState.rawValue)")
            updateActivity("Session state: \(toState.rawValue)")
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            log("session error: \(error.localizedDescription)")
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            for item in data {
                let message = String(decoding: item, as: UTF8.self)
                log("received: \(message)")
                updateActivity(message)
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in
            log("remote disconnected: \(error?.localizedDescription ?? "clean")")
        }
    }
}
