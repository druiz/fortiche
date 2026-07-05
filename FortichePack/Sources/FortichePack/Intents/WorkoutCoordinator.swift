import Foundation

/// The app-side surface App Intents drive. The app target registers a concrete
/// implementation at launch; intents call through this so the package doesn't
/// depend on the app's controllers.
@MainActor
public protocol WorkoutCoordinating: AnyObject {
    /// Start the given day (by template-day UUID). Returns a short confirmation
    /// phrase, or nil if it couldn't start.
    func startWorkout(dayID: UUID) async -> String?
    /// Currently-active engine, if any (for mid-workout intents).
    var activeEngine: ActiveWorkoutEngine? { get }
    /// Log the current set with the given reps (and optional weight in kg).
    func logCurrentSet(reps: Int?, weightKg: Double?) -> String?
    /// End the active workout.
    func endWorkout() async
}

@MainActor
public enum WorkoutCoordinatorRegistry {
    public static var current: (any WorkoutCoordinating)?
}
