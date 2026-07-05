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

    var activeEngine: ActiveWorkoutEngine? {
        PhoneWorkoutController.shared.engine ?? MirroringReceiver.shared.engine
    }

    func startWorkout(dayID: UUID) async -> String? {
        guard activeEngine == nil else { return nil }
        let context = container.mainContext
        let descriptor = FetchDescriptor<TemplateDay>(predicate: #Predicate { $0.uuid == dayID })
        guard let day = try? context.fetch(descriptor).first else { return nil }
        let name = day.name
        await PhoneWorkoutController.shared.start(day: day)
        return "Starting \(name). Let's go!"
    }

    func logCurrentSet(reps: Int?, weightKg: Double?) -> String? {
        guard let engine = activeEngine,
              let logged = engine.completeCurrentSet(reps: reps, weightKg: weightKg) else { return nil }
        let unit = WeightUnit.preferred
        let weightText = logged.weightKg.map { " at \(unit.format(kilograms: $0))" } ?? ""
        return "Logged \(logged.reps) reps\(weightText)."
    }

    func endWorkout() async {
        if PhoneWorkoutController.shared.isActive {
            await PhoneWorkoutController.shared.end(in: container.mainContext)
        } else if MirroringReceiver.shared.isActive {
            MirroringReceiver.shared.engine?.submit(.end)
        }
    }
}
