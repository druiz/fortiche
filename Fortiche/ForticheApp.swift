import SwiftUI
import SwiftData
import FortichePack

@main
struct ForticheApp: App {
    // NOTE (M3): the HealthKit mirroring start handler must be installed
    // synchronously here in the App initializer — the system launches this
    // app in the background when the watch starts mirroring, and a lazily
    // installed handler silently drops the session.
    let container: ModelContainer

    init() {
        do {
            container = try ForticheStore.container(.phone)
        } catch {
            fatalError("Unable to open the Fortiche data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
