#if canImport(AppIntents) && !os(watchOS)
import AppIntents
import Foundation

/// "Start my Push day" — begins a workout for a chosen template day.
/// Surfaces to Siri, Spotlight, the Action button, and Control Center.
public struct StartForticheWorkoutIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Workout"
    public static let description = IntentDescription("Start one of your Fortiche training days.")
    public static let openAppWhenRun = true

    @Parameter(title: "Day")
    public var day: WorkoutDayEntity

    public init() {}
    public init(day: WorkoutDayEntity) { self.day = day }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let coordinator = WorkoutCoordinatorRegistry.current else {
            throw IntentError.unavailable
        }
        guard let confirmation = await coordinator.startWorkout(dayID: day.id) else {
            return .result(dialog: "Couldn't start \(day.name).")
        }
        return .result(dialog: IntentDialog(stringLiteral: confirmation))
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$day)")
    }
}

/// "Log 8 reps at 80 kilos" — records the current set hands-free.
public struct LogSetIntent: AppIntent {
    public static let title: LocalizedStringResource = "Log Set"
    public static let description = IntentDescription("Log the current set of your active workout.")

    @Parameter(title: "Reps")
    public var reps: Int?

    @Parameter(title: "Weight (kg)")
    public var weightKg: Double?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let coordinator = WorkoutCoordinatorRegistry.current,
              coordinator.activeEngine != nil else {
            return .result(dialog: "No workout is in progress.")
        }
        guard let message = coordinator.logCurrentSet(reps: reps, weightKg: weightKg) else {
            return .result(dialog: "That exercise is already finished.")
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// "Skip my rest" during an active workout.
public struct SkipRestSiriIntent: AppIntent {
    public static let title: LocalizedStringResource = "Skip Rest Timer"
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = WorkoutCoordinatorRegistry.current?.activeEngine else {
            return .result(dialog: "No workout is in progress.")
        }
        engine.submit(.skipRest)
        return .result(dialog: "Rest skipped.")
    }
}

/// "Next exercise" — skip to the next movement.
public struct NextExerciseIntent: AppIntent {
    public static let title: LocalizedStringResource = "Next Exercise"
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = WorkoutCoordinatorRegistry.current?.activeEngine else {
            return .result(dialog: "No workout is in progress.")
        }
        engine.submit(.skipExercise(engine.state.currentExerciseIndex))
        let next = engine.state.currentExercise?.name ?? "the next exercise"
        return .result(dialog: "Moving on to \(next).")
    }
}

/// Lets the app target pull AppIntents metadata out of this package.
public struct FortichePackage: AppIntentsPackage {}

/// Spoken failure for intents that run before the app has registered its
/// coordinator (e.g. cold-launch races).
public enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: "Fortiche isn't ready yet."
        }
    }
}

/// Natural-language phrases for Siri and the Shortcuts app.
public struct ForticheShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartForticheWorkoutIntent(),
            phrases: [
                "Start a workout in \(.applicationName)",
                "Start my \(\.$day) in \(.applicationName)",
                "Begin \(\.$day) with \(.applicationName)",
            ],
            shortTitle: "Start Workout",
            systemImageName: "figure.strengthtraining.traditional"
        )
        AppShortcut(
            intent: LogSetIntent(),
            phrases: [
                "Log a set in \(.applicationName)",
                "Log my set with \(.applicationName)",
            ],
            shortTitle: "Log Set",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: SkipRestSiriIntent(),
            phrases: [
                "Skip my rest in \(.applicationName)",
                "Skip the rest timer in \(.applicationName)",
            ],
            shortTitle: "Skip Rest",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: NextExerciseIntent(),
            phrases: [
                "Next exercise in \(.applicationName)",
                "Move to the next exercise in \(.applicationName)",
            ],
            shortTitle: "Next Exercise",
            systemImageName: "forward.end.fill"
        )
    }
}
#endif
