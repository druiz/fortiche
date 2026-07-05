#if canImport(ActivityKit) && !os(macOS)
import AppIntents
import Foundation
import os

/// Intents behind the Live Activity's interactive buttons. `LiveActivityIntent`
/// performs in the app's process, where `WorkoutIntentBridge` is wired to the
/// active workout host (authoritative controller or mirror client).
public struct SkipRestIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Skip Rest"
    public static let isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await WorkoutIntentBridge.shared.submit(.skipRest)
        return .result()
    }
}

public struct PauseResumeIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or Resume Workout"
    public static let isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await WorkoutIntentBridge.shared.togglePause()
        return .result()
    }
}

/// Big green "Done Set" button on the Live Activity — logs the current set at
/// its prescription without unlocking the phone.
public struct CompleteSetIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Complete Set"
    public static let isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await WorkoutIntentBridge.shared.completeCurrentSet()
        return .result()
    }
}

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

    func submit(_ command: WorkoutCommand) {
        Self.logger.info("live-activity intent: \(String(describing: command), privacy: .public)")
        engine(for: "submit")?.submit(command)
    }

    func togglePause() {
        guard let engine = engine(for: "togglePause") else { return }
        engine.submit(engine.state.phase == .paused ? .resume : .pause)
    }

    func completeCurrentSet() {
        Self.logger.info("live-activity intent: completeCurrentSet")
        engine(for: "completeCurrentSet")?.completeCurrentSet()
    }
}
#endif
