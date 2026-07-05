import Foundation
import HealthKit
import os

/// M1.5 spike: bare workout session + mirroring + data round-trip.
/// Throwaway — replaced by the real session controller in M3.
@MainActor
final class SpikeWorkoutController: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: "com.davidruiz.fortiche.watch", category: "spike")

    let healthStore = HKHealthStore()
    @Published private(set) var events: [String] = []
    @Published private(set) var isRunning = false

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    func start() async {
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
            )
            log("health authorized")

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .functionalStrengthTraining
            configuration.locationType = .indoor

            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session.delegate = self
            self.session = session

            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            self.builder = builder

            session.startActivity(with: .now)
            try await builder.beginCollection(at: .now)
            isRunning = true
            log("session started")

            try await session.startMirroringToCompanionDevice()
            log("mirroring to phone started")
        } catch {
            log("error: \(error.localizedDescription)")
        }
    }

    func end() {
        session?.stopActivity(with: .now)
        session?.end()
        isRunning = false
        log("session ended")
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

    private func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        events.append(message)
    }
}

extension SpikeWorkoutController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            log("state \(fromState.rawValue) → \(toState.rawValue)")
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
                // Echo back to complete the round trip the phone initiated.
                send("echo: \(message)")
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
