import Foundation
import HealthKit
import Observation
import SwiftData
import WatchKit
import FortichePack
import os

/// Watch-authoritative workout host: owns the engine, the HKWorkoutSession +
/// live builder, and replication to the phone. Commands arrive from the phone
/// over the mirrored-session channel (or the WC debug transport on simulators);
/// after every applied command the full state snapshot is echoed back.
@Observable @MainActor
final class WatchWorkoutController: NSObject {
    static let shared = WatchWorkoutController()
    private static let logger = Logger(subsystem: "com.davidruiz.fortiche.watch", category: "workout")

    private(set) var engine: ActiveWorkoutEngine?
    var isActive: Bool { engine != nil }

    @ObservationIgnored let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var restTick: Task<Void, Never>?
    @ObservationIgnored private var mirrorRetry: Task<Void, Never>?

    private(set) var heartRate: Double?

    override private init() {
        super.init()
        // Simulator debug transport: commands from the phone arrive over WC.
        ConnectivityHub.shared.onLiveMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        ConnectivityHub.shared.onReachabilityChange = { [weak self] reachable in
            guard reachable else { return }
            Task { @MainActor in
                if let engine = self?.engine {
                    self?.sendToPhone(.snapshot(engine.state))
                }
            }
        }
    }

    // MARK: Lifecycle

    func start(day: TemplateDay) async {
        guard engine == nil else { return }
        beginEngine(with: WorkoutState.start(day: day, host: .watch))
        await startHealthKitSession()
    }

    /// HealthKit + engine crash recovery, called at app launch.
    func recoverIfNeeded() {
        guard engine == nil else { return }
        healthStore.recoverActiveWorkoutSession { [weak self] session, _ in
            Task { @MainActor in
                guard let self else { return }
                // Re-check: a workout may have started while the async HK
                // recovery query was in flight (its journal is NOT a crash).
                guard self.engine == nil else { return }
                if let recovered = ActiveWorkoutEngine.recover(localHost: .watch), recovered.state.host == .watch {
                    Self.logger.info("recovered workout \(recovered.state.workoutUUID, privacy: .public)")
                    self.adoptEngine(recovered)
                    if let session {
                        self.attachSession(session)
                    } else {
                        Task { await self.startHealthKitSession() }
                    }
                } else if let session {
                    // HK session exists but no journal — end the orphan.
                    session.end()
                }
            }
        }
    }

    func end(in modelContext: ModelContext) async {
        guard let engine else { return }
        engine.submit(.end)
        let state = engine.state

        // Local log (watch store is offline-first).
        let log = state.makeLog()
        modelContext.insert(log)
        try? modelContext.save()

        // Ship to the phone on both channels; phone upserts by UUID.
        let finished = FinishedWorkoutDTO(state: state)
        sendToPhone(.snapshot(state))
        ConnectivityHub.shared.queueFinishedWorkout(finished)

        // Finish HealthKit.
        if let builder, let session {
            session.stopActivity(with: state.endedAt ?? .now)
            session.end()
            do {
                try await builder.endCollection(at: state.endedAt ?? .now)
                try await builder.finishWorkout()
            } catch {
                Self.logger.error("HK save failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        mirrorRetry?.cancel()
        restTick?.cancel()
        session = nil
        builder = nil
        self.engine = nil
        ActiveWorkoutEngine.clearJournal()
    }

    // MARK: Engine wiring

    private func beginEngine(with state: WorkoutState) {
        adoptEngine(ActiveWorkoutEngine(state: state, localHost: .watch))
    }

    private func adoptEngine(_ engine: ActiveWorkoutEngine) {
        engine.onStateChange = { [weak self] state in
            self?.sendToPhone(.snapshot(state))
        }
        engine.onRestChange = { [weak self] deadline in
            if deadline == nil { self?.playRestEndedHaptic() }
        }
        self.engine = engine
        startRestTicker()
        // Announce the session so the phone can raise its live UI immediately
        // (on real devices the mirrored-session launch does this too; over the
        // WC debug transport this is the only signal).
        sendToPhone(.snapshot(engine.state))
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

    private func playRestEndedHaptic() {
        WKInterfaceDevice.current().play(.notification)
    }

    // MARK: HealthKit session

    private func startHealthKitSession() async {
        guard let engine else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = engine.state.activityKind == .traditional
            ? .traditionalStrengthTraining : .functionalStrengthTraining
        configuration.locationType = .indoor

        // `--skip-health` keeps headless demo runs free of permission sheets.
        guard !ProcessInfo.processInfo.arguments.contains("--skip-health") else { return }
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
            )
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            builder.delegate = self
            attachSession(session)
            self.builder = builder
            session.startActivity(with: engine.state.startedAt)
            try await builder.beginCollection(at: engine.state.startedAt)
            startMirroringWithRetry()
        } catch {
            Self.logger.error("HK session start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func attachSession(_ session: HKWorkoutSession) {
        session.delegate = self
        self.session = session
    }

    /// The mirroring call can "succeed" while delivery fails (see
    /// docs/SPIKE-M1.5.md) and the phone may be unreachable at start — retry
    /// with backoff for the life of the workout; the snapshot handshake
    /// resyncs whenever the phone attaches.
    private func startMirroringWithRetry() {
        mirrorRetry?.cancel()
        mirrorRetry = Task { [weak self] in
            var delay: Duration = .seconds(2)
            while !Task.isCancelled {
                guard let self, let session = await self.session else { return }
                do {
                    try await session.startMirroringToCompanionDevice()
                    Self.logger.info("mirroring started")
                    return
                } catch {
                    Self.logger.info("mirroring attempt failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: delay)
                delay = min(.seconds(60), delay * 2)
            }
        }
    }

    // MARK: Replication

    private func handle(_ message: SyncMessage) {
        guard let engine else { return }
        switch message {
        case .command(let envelope):
            engine.apply(envelope) // triggers onStateChange → snapshot echo
        case .requestSnapshot:
            sendToPhone(.snapshot(engine.state))
        case .snapshot:
            break // authority never adopts snapshots
        }
    }

    private func sendToPhone(_ message: SyncMessage) {
        // Production channel: mirrored session.
        if let session, let data = try? message.encoded() {
            session.sendToRemoteWorkoutSession(data: data) { _, _ in }
        }
        // Debug channel (simulators): WatchConnectivity.
        ConnectivityHub.shared.sendLive(message)
    }
}

extension WatchWorkoutController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            Self.logger.error("session error: \(error.localizedDescription, privacy: .public)")
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
            Self.logger.info("phone disconnected: \(error?.localizedDescription ?? "clean", privacy: .public)")
            self.startMirroringWithRetry()
        }
    }
}

extension WatchWorkoutController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(HKQuantityType(.heartRate)) else { return }
        let bpm = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?
            .mostRecentQuantity()?
            .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor in
            self.heartRate = bpm
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
