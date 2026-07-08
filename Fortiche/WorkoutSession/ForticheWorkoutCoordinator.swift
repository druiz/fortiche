import Foundation
import SwiftData
import FortichePack

/// Bridges App Intents to the phone's workout hosts. Registered at launch in
/// `WorkoutCoordinatorRegistry`.
@MainActor
final class ForticheWorkoutCoordinator: WorkoutCoordinating {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// Whichever engine is live: the phone-authoritative controller, or the
    /// peer engine mirroring a watch-run session. At most one exists at a time.
    var activeEngine: ActiveWorkoutEngine? {
        PhoneWorkoutController.shared.engine ?? MirroringReceiver.shared.engine
    }

    /// Start a phone-hosted workout for a template day. Returns the spoken
    /// confirmation, or nil (Siri reports failure) when a workout is already
    /// running or the day no longer exists.
    func startWorkout(dayID: UUID) async -> String? {
        guard activeEngine == nil else { return nil }
        let context = container.mainContext
        let descriptor = FetchDescriptor<TemplateDay>(predicate: #Predicate { $0.uuid == dayID })
        guard let day = try? context.fetch(descriptor).first else { return nil }
        let name = day.name
        await PhoneWorkoutController.shared.start(day: day)
        return "Starting \(name). Let's go!"
    }

    /// Complete the current set (defaults fill in unspecified reps/weight) and
    /// phrase the result for Siri in the user's display unit.
    func logCurrentSet(reps: Int?, weightKg: Double?) -> String? {
        guard let engine = activeEngine,
              let logged = engine.completeCurrentSet(reps: reps, weightKg: weightKg) else { return nil }
        let unit = WeightUnit.preferred
        let weightText = logged.weightKg.map { " at \(unit.format(kilograms: $0))" } ?? ""
        return "Logged \(logged.reps) reps\(weightText)."
    }

    /// End via the active host. A phone-hosted workout saves locally; for a
    /// mirrored watch session only `.end` is submitted — the watch is the
    /// authority and owns persistence.
    func endWorkout() async {
        if PhoneWorkoutController.shared.isActive {
            await PhoneWorkoutController.shared.end(in: container.mainContext)
        } else if MirroringReceiver.shared.isActive {
            MirroringReceiver.shared.engine?.submit(.end)
        }
    }

    /// Retroactive mini-workout (Quick Log) — no live session involved.
    /// The exercise name is fuzzy-matched into the library when confident.
    func quickLog(exerciseName: String, sets: Int, reps: Int, weightKg: Double?) async -> String? {
        let name = exerciseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, sets > 0, reps > 0 else { return nil }
        let match = ExerciseMatcher.confidentMatch(for: name, in: .shared)
        let state = WorkoutState.quickEntry(
            exerciseName: match?.name ?? name,
            librarySlug: match?.slug,
            sets: sets,
            reps: reps,
            weightKg: weightKg
        )
        await QuickLogController.shared.save(state: state, in: container.mainContext)
        let weightText = weightKg.map { " at \(WeightUnit.preferred.format(kilograms: $0))" } ?? ""
        return "Logged \(sets) sets of \(reps) \(match?.name ?? name)\(weightText). Nice work!"
    }
}
