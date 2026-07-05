import SwiftUI
import SwiftData
import FortichePack

@main
struct ForticheApp: App {
    let container: ModelContainer

    init() {
        // The mirroring start handler must be installed synchronously here —
        // the system launches this app in the background when the watch starts
        // mirroring, and a lazily installed handler silently drops the session.
        MirroringReceiver.shared.install()
        do {
            container = try ForticheStore.container(.phone)
        } catch {
            fatalError("Unable to open the Fortiche data store: \(error)")
        }
        MirroringReceiver.shared.modelContainer = container
        // Live Activity buttons route to whichever engine is active. The
        // fallback restores a phone-run workout from its journal when a button
        // relaunches the app in the background (no UI = no normal recovery).
        WorkoutIntentBridge.shared.engineProvider = {
            PhoneWorkoutController.shared.engine ?? MirroringReceiver.shared.engine
        }
        WorkoutIntentBridge.shared.recoveryFallback = {
            PhoneWorkoutController.shared.recoverIfNeeded()
        }
        // App Intents / Siri drive the workout through this coordinator.
        WorkoutCoordinatorRegistry.current = ForticheWorkoutCoordinator(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

/// Push the full template catalog to the watch. Called after any template
/// mutation and once per launch (applicationContext delivers the latest
/// version whenever the watch next runs).
@MainActor
func pushTemplatesToWatch(_ context: ModelContext) {
    let templates = (try? context.fetch(FetchDescriptor<WorkoutTemplate>())) ?? []
    ConnectivityHub.shared.pushTemplates(templates.map(TemplateDTO.init))
}
