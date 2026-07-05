import AppIntents
import FortichePack
import Foundation

// The Live Activity's button intents.
//
// This file is deliberately compiled into BOTH the iOS app and the widget
// extension (see `Shared` in each target's sources in project.yml) rather
// than living in FortichePack. Package-hosted Live Activity intents extract
// metadata without per-bundle type mappings (`effectiveBundleIdentifiers` is
// empty), and the system then drops button taps on the floor. Compiling the
// same source into each target gives every binary its own registered copy,
// which is the configuration Apple's samples use.
//
// `LiveActivityIntent` performs in the app's process, where
// `WorkoutIntentBridge` (in FortichePack) is wired to the live engine.

/// Skips the running rest timer.
struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Rest"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await WorkoutIntentBridge.shared.submit(.skipRest)
        return .result()
    }
}

/// Toggles pause/resume on the active workout.
struct PauseResumeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Workout"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await WorkoutIntentBridge.shared.togglePause()
        return .result()
    }
}

/// Logs the current set at its prescription without unlocking the phone.
struct CompleteSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete Set"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await WorkoutIntentBridge.shared.completeCurrentSet()
        return .result()
    }
}
