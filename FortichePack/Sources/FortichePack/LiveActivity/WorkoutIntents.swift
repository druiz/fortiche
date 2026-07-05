#if canImport(ActivityKit) && !os(macOS)
import AppIntents
import Foundation

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
@MainActor
public final class WorkoutIntentBridge {
    public static let shared = WorkoutIntentBridge()
    public var engineProvider: (() -> ActiveWorkoutEngine?)?

    func submit(_ command: WorkoutCommand) {
        engineProvider?()?.submit(command)
    }

    func togglePause() {
        guard let engine = engineProvider?() else { return }
        engine.submit(engine.state.phase == .paused ? .resume : .pause)
    }

    func completeCurrentSet() {
        engineProvider?()?.completeCurrentSet()
    }
}
#endif
