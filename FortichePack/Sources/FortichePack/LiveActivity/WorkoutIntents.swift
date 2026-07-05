#if canImport(ActivityKit) && !os(macOS)
import Foundation
import os

// NOTE: the Live Activity button intents themselves live in
// Shared/LiveActivityIntents.swift, compiled directly into both the app and
// widget targets — package-hosted LiveActivityIntents extract metadata
// without per-bundle type mappings and their button taps go nowhere. Only
// the bridge they call lives here.

/// Routes intent invocations to whichever engine is currently active.
/// App targets set `engineProvider` at launch.
///
/// When a Live Activity button relaunches the app in the *background*, the UI
/// (and its recovery path) never appears, so the provider may find no engine.
/// `recoveryFallback` — also set at launch — gets a chance to restore one from
/// the on-disk journal before the tap is dropped.
@MainActor
public final class WorkoutIntentBridge {
    public static let shared = WorkoutIntentBridge()
    private static let logger = Logger(subsystem: "com.davidruiz.fortiche", category: "intents")

    public var engineProvider: (() -> ActiveWorkoutEngine?)?
    public var recoveryFallback: (() -> Void)?

    private func engine(for action: String) -> ActiveWorkoutEngine? {
        if let engine = engineProvider?() { return engine }
        Self.logger.info("\(action, privacy: .public): no engine — attempting journal recovery")
        recoveryFallback?()
        let recovered = engineProvider?()
        if recovered == nil {
            Self.logger.error("\(action, privacy: .public): dropped, no active workout")
        }
        return recovered
    }

    public func submit(_ command: WorkoutCommand) {
        Self.logger.info("live-activity intent: \(String(describing: command), privacy: .public)")
        engine(for: "submit")?.submit(command)
    }

    public func togglePause() {
        guard let engine = engine(for: "togglePause") else { return }
        engine.submit(engine.state.phase == .paused ? .resume : .pause)
    }

    public func completeCurrentSet() {
        Self.logger.info("live-activity intent: completeCurrentSet")
        engine(for: "completeCurrentSet")?.completeCurrentSet()
    }
}
#endif
