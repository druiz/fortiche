import SwiftUI
import SwiftData
import FortichePack

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Programs", systemImage: "list.bullet.rectangle") {
                TemplateListView()
            }
            Tab("History", systemImage: "clock") {
                HistoryPlaceholderView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsPlaceholderView()
            }
        }
    }
}

struct TemplateListView: View {
    @Query(sort: \WorkoutTemplate.createdAt, order: .reverse) private var templates: [WorkoutTemplate]

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No programs yet",
                        systemImage: "square.and.pencil",
                        description: Text("Paste a workout program as text and Fortiche will turn it into a structured plan.")
                    )
                } else {
                    List(templates) { template in
                        VStack(alignment: .leading) {
                            Text(template.name).font(.headline)
                            Text("\(template.orderedDays.count) days")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Programs")
        }
    }
}

struct HistoryPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No workouts yet",
                systemImage: "figure.strengthtraining.traditional",
                description: Text("Finished workouts will appear here and in Apple Health.")
            )
            .navigationTitle("History")
        }
    }
}

struct SettingsPlaceholderView: View {
    @ObservedObject private var mirroring = MirroringReceiver.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Mirroring spike (M1.5)") {
                    if mirroring.events.isEmpty {
                        Text("Waiting for a workout to start on the watch…")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(mirroring.events.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                await mirroring.requestAuthorization()
            }
        }
    }
}

#Preview {
    RootView()
        .modelContainer(try! ForticheStore.container(.inMemory))
}
