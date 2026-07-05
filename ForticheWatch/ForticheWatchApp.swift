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
    @StateObject private var spike = SpikeWorkoutController()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if spike.isRunning {
                        Button("End Spike", role: .destructive) { spike.end() }
                    } else {
                        Button("Start Spike") {
                            Task { await spike.start() }
                        }
                    }
                    ForEach(Array(spike.events.suffix(6).enumerated()), id: \.offset) { _, event in
                        Text(event).font(.footnote)
                    }
                } header: {
                    Text("Mirroring spike")
                }

                Section {
                    if templates.isEmpty {
                        Text("Add a program on your iPhone to get started.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(templates) { template in
                            Text(template.name)
                        }
                    }
                } header: {
                    Text("Programs")
                }
            }
            .navigationTitle("Fortiche")
            .task {
                // CLI automation hook: `simctl launch … --spike-autostart`
                if ProcessInfo.processInfo.arguments.contains("--spike-autostart"), !spike.isRunning {
                    await spike.start()
                }
            }
        }
    }
}
