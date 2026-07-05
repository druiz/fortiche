import SwiftUI
import SwiftData
import FortichePack

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]
    private let unit = WeightUnit.preferred

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty {
                    ContentUnavailableView(
                        "No workouts yet",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Finished workouts appear here and in Apple Health.")
                    )
                } else {
                    List {
                        ForEach(logs) { log in
                            NavigationLink {
                                WorkoutSummaryView(log: log)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.title).font(.headline)
                                    Text(subtitle(for: log))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets { modelContext.delete(logs[offset]) }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func subtitle(for log: WorkoutLog) -> String {
        var parts = [log.startedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append("\(log.totalSets) sets")
        if log.totalVolumeKg > 0 {
            parts.append(unit.format(kilograms: log.totalVolumeKg))
        }
        return parts.joined(separator: " · ")
    }
}

struct WorkoutSummaryView: View {
    let log: WorkoutLog
    private let unit = WeightUnit.preferred

    var body: some View {
        List {
            Section {
                HStack {
                    metric("Duration", log.duration.map(format(duration:)) ?? "—")
                    Divider()
                    metric("Sets", "\(log.totalSets)")
                    Divider()
                    metric("Volume", log.totalVolumeKg > 0 ? unit.format(kilograms: log.totalVolumeKg) : "—")
                }
                .frame(maxWidth: .infinity)
            }
            ForEach(log.orderedExercises) { exercise in
                Section(exercise.name) {
                    ForEach(exercise.orderedSets) { set in
                        HStack {
                            Text("Set \(set.order + 1)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(set.reps) × \(set.weightKg.map { unit.format(kilograms: $0) } ?? "BW")")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle(log.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func format(duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
