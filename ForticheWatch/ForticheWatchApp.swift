import SwiftUI
import SwiftData
import FortichePack
import os

@main
struct ForticheWatchApp: App {
    let container: ModelContainer

    init() {
        do {
            // Watch store is local-only; templates arrive over WatchConnectivity.
            container = try ForticheStore.container(.watch)
        } catch {
            fatalError("Unable to open the Fortiche data store: \(error)")
        }
        ConnectivityHub.shared.activate()
        installTemplateReceiver()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
        .modelContainer(container)
    }

    /// Upsert template catalog pushes from the phone into the local store.
    private func installTemplateReceiver() {
        let container = self.container
        ConnectivityHub.shared.onTemplatesReceived = { templates in
            Task { @MainActor in
                // The phone pushes its complete catalog — replace wholesale.
                let context = container.mainContext
                let existing = (try? context.fetch(FetchDescriptor<WorkoutTemplate>())) ?? []
                existing.forEach { context.delete($0) }
                templates.forEach { context.insert($0.makeTemplate()) }
                try? context.save()
            }
        }
    }
}

struct WatchRootView: View {
    @Query(sort: \WorkoutTemplate.createdAt, order: .reverse) private var templates: [WorkoutTemplate]
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]
    @State private var controller = WatchWorkoutController.shared

    var body: some View {
        NavigationStack {
            if controller.isActive {
                WatchLiveWorkoutView(controller: controller)
            } else {
                dayList
            }
        }
        .task {
            controller.recoverIfNeeded()
        }
        .task(id: templates.count) {
            // CLI automation hook: start the first day of the first template.
            let logger = Logger(subsystem: "com.davidruiz.fortiche.watch", category: "demo")
            logger.info("demo hook: templates=\(templates.count) args=\(ProcessInfo.processInfo.arguments.joined(separator: " "), privacy: .public)")
            if ProcessInfo.processInfo.arguments.contains("--demo-workout"),
               !controller.isActive,
               let day = templates.first?.orderedDays.first {
                logger.info("demo hook: starting \(day.name, privacy: .public)")
                await controller.start(day: day)
                logger.info("demo hook: started, isActive=\(controller.isActive)")
            }
        }
    }

    private var dayList: some View {
        List {
            if templates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Add a program on your iPhone to get started.")
                        .multilineTextAlignment(.center)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } else {
                ForEach(templates) { template in
                    let nextDay = ProgramSchedule.nextDay(in: template, logs: logs)
                    Section(template.name) {
                        ForEach(template.orderedDays) { day in
                            let isNextUp = day.uuid == nextDay?.uuid
                            Button {
                                Task { await controller.start(day: day) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        HStack(spacing: 4) {
                                            Text(day.name).font(.headline)
                                            if isNextUp {
                                                Image(systemName: "arrow.forward.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        Text(isNextUp ? "Next up" : "^[\(day.orderedExercises.count) exercise](inflect: true)")
                                            .font(.caption2)
                                            .foregroundStyle(isNextUp ? .green : .secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(isNextUp ? .green : .secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Fortiche")
    }
}
