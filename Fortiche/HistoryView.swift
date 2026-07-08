import Charts
import SwiftUI
import SwiftData
import FortichePack

/// History tab: weekly volume chart, personal records, and the full workout
/// log, newest first. Rows delete straight from the store — logs are the
/// source of truth for stats, so removal reshapes the chart and records too.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]
    @State private var showingQuickLog = false
    private let unit = WeightUnit.preferred

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty {
                    ContentUnavailableView {
                        Label("No workouts yet", systemImage: "figure.strengthtraining.traditional")
                    } description: {
                        Text("Finished workouts appear here and in Apple Health. A few sets off-program count too - start a quick workout.")
                    } actions: {
                        Button("Quick Workout", systemImage: "bolt.fill") { showingQuickLog = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if logs.count >= 2 {
                            Section("Weekly volume") {
                                VolumeChart(logs: logs, unit: unit)
                            }
                        }
                        Section("Records") {
                            PersonalRecordsView(logs: logs, unit: unit)
                        }
                        ForEach(logs) { log in
                            NavigationLink {
                                WorkoutSummaryView(log: log)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(log.title).font(.headline)
                                        if log.kind == .quick {
                                            Image(systemName: "bolt.fill")
                                                .font(.caption)
                                                .foregroundStyle(.yellow)
                                                .accessibilityLabel("Quick log")
                                        }
                                    }
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Quick Workout", systemImage: "bolt.fill") { showingQuickLog = true }
                }
            }
            .sheet(isPresented: $showingQuickLog) {
                QuickWorkoutView()
            }
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

/// Bar chart of lifted volume per training day, in the display unit.
struct VolumeChart: View {
    let logs: [WorkoutLog]
    let unit: WeightUnit

    var body: some View {
        Chart(WorkoutStats.dailyVolume(from: logs)) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Volume", unit.fromKilograms(point.volumeKg))
            )
            .foregroundStyle(.tint)
        }
        .frame(height: 140)
    }
}

/// Top lifts per exercise, ranked by estimated one-rep max (best first).
struct PersonalRecordsView: View {
    let logs: [WorkoutLog]
    let unit: WeightUnit

    private var records: [WorkoutStats.ExerciseBest] {
        WorkoutStats.personalRecords(from: logs).values
            .sorted { $0.bestEstimatedOneRepMaxKg > $1.bestEstimatedOneRepMaxKg }
    }

    var body: some View {
        if records.isEmpty {
            Text("Complete weighted sets to see records.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(records.prefix(6), id: \.slugOrName) { record in
                HStack {
                    Text(record.slugOrName).lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("\(record.bestSetReps) × \(unit.format(kilograms: record.bestSetWeightKg))")
                            .monospacedDigit()
                        Text("e1RM \(unit.format(kilograms: record.bestEstimatedOneRepMaxKg))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Read-only detail for one finished workout: headline metrics
/// (duration/sets/volume) plus every logged set per exercise.
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
