import SwiftUI
import SwiftData
import FortichePack

@main
struct ForticheWatchApp: App {
    let container: ModelContainer

    init() {
        do {
            // Watch store is local-only; templates sync over WatchConnectivity.
            container = try ForticheStore.container(.watch)
        } catch {
            fatalError("Unable to open the Fortiche data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
        .modelContainer(container)
    }
}

struct WatchRootView: View {
    @Query(sort: \WorkoutTemplate.createdAt, order: .reverse) private var templates: [WorkoutTemplate]

    var body: some View {
        NavigationStack {
            if templates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Add a program on your iPhone to get started.")
                        .multilineTextAlignment(.center)
                        .font(.footnote)
                }
                .navigationTitle("Fortiche")
            } else {
                List(templates) { template in
                    Text(template.name)
                }
                .navigationTitle("Fortiche")
            }
        }
    }
}
