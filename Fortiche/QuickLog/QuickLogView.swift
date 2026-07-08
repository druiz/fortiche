import SwiftUI
import SwiftData
import FortichePack

/// Retroactive "mini workout" entry — crunches in front of the TV, logged in
/// two steps: pick the exercise (recents first), confirm sets × reps, done.
/// Deliberately has no timer and no template; the reward is the record.
struct QuickLogView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]

    @State private var search = ""
    @State private var selection: Selection?
    @State private var sets = 3
    @State private var reps = 15
    @State private var useWeight = false
    @State private var weight = 10.0
    @State private var saved: WorkoutLog?

    private let unit = WeightUnit.preferred

    struct Selection: Equatable {
        var name: String
        var librarySlug: String?
    }

    var body: some View {
        NavigationStack {
            Group {
                if saved != nil {
                    successView
                } else if let selection {
                    amountsView(selection)
                } else {
                    pickerView
                }
            }
            .navigationTitle("Quick Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Step 1 — exercise

    /// Distinct recently-logged exercise names, most recent first — the
    /// "crunches again" case should be a single tap.
    private var recents: [Selection] {
        var seen = Set<String>()
        var result: [Selection] = []
        for log in logs {
            for exercise in log.orderedExercises {
                let key = exercise.librarySlug ?? exercise.name.lowercased()
                if seen.insert(key).inserted {
                    result.append(Selection(name: exercise.name, librarySlug: exercise.librarySlug))
                }
            }
            if result.count >= 8 { return result }
        }
        return result
    }

    private var pickerView: some View {
        List {
            Section {
                TextField("Exercise — crunches, curls, push-ups…", text: $search)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit {
                        let trimmed = search.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        select(Selection(
                            name: trimmed,
                            librarySlug: ExerciseMatcher.confidentMatch(for: trimmed, in: .shared)?.slug
                        ))
                    }
            }

            if search.isEmpty {
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.name) { recent in
                            Button {
                                select(recent)
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    Text(recent.name).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            } else {
                Section("Library") {
                    ForEach(ExerciseLibrary.shared.fuzzyMatches(name: search, limit: 6), id: \.exercise.id) { match in
                        Button {
                            select(Selection(name: match.exercise.name, librarySlug: match.exercise.slug))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(match.exercise.name).foregroundStyle(.primary)
                                if let muscle = match.exercise.primaryMuscles.first {
                                    Text(muscle.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button {
                        select(Selection(name: search.trimmingCharacters(in: .whitespaces), librarySlug: nil))
                    } label: {
                        Label("Use “\(search)”", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    /// Prefill from the last time this exercise was performed, then advance.
    private func select(_ choice: Selection) {
        if let last = WorkoutStats.lastPerformance(
            ofSlug: choice.librarySlug, name: choice.name, before: .now, in: logs
        ) {
            reps = last.reps
            if let kg = last.weightKg {
                useWeight = true
                weight = unit.roundedForDisplay(unit.fromKilograms(kg))
            }
        }
        withAnimation { selection = choice }
    }

    // MARK: Step 2 — amounts

    private func amountsView(_ selection: Selection) -> some View {
        VStack(spacing: 20) {
            HStack {
                Text(selection.name).font(.title2.bold())
                Spacer()
                Button("Change") { withAnimation { self.selection = nil } }
                    .font(.subheadline)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                stepperCard(title: "Sets", value: $sets, range: 1...10, step: 1)
                stepperCard(title: "Reps", value: $reps, range: 1...100, step: 1)
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                Toggle("Weighted", isOn: $useWeight.animation())
                    .padding(.horizontal)
                if useWeight {
                    HStack {
                        Button("−") { weight = max(0, weight - unit.displayStep) }
                            .buttonStyle(.bordered)
                        Text("\(weight.formatted()) \(unit.symbol)")
                            .font(.title3.monospacedDigit().bold())
                            .frame(maxWidth: .infinity)
                        Button("+") { weight += unit.displayStep }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                }
            }

            Spacer()

            Button {
                Task { await save(selection) }
            } label: {
                Text("Log It — \(sets) × \(reps)\(useWeight ? " @ \(weight.formatted()) \(unit.symbol)" : "")")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .padding(.top)
    }

    private func stepperCard(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value.wrappedValue)").font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            HStack {
                Button("−") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) }
                    .buttonStyle(.bordered)
                Button("+") { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func save(_ selection: Selection) async {
        let state = WorkoutState.quickEntry(
            exerciseName: selection.name,
            librarySlug: selection.librarySlug,
            sets: sets,
            reps: reps,
            weightKg: useWeight ? unit.toKilograms(weight) : nil
        )
        let log = await QuickLogController.shared.save(state: state, in: modelContext)
        withAnimation(.bouncy) { saved = log }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        try? await Task.sleep(for: .seconds(1.6))
        dismiss()
    }

    // MARK: Done

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: saved)
            Text("Logged!").font(.title2.bold())
            if let saved {
                Text("\(saved.title) · \(sets) × \(reps)\(useWeight ? " @ \(weight.formatted()) \(unit.symbol)" : "")")
                    .foregroundStyle(.secondary)
            }
            Text("Counted in this week's volume — and in Apple Health.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    QuickLogView()
        .modelContainer(try! ForticheStore.container(.inMemory))
}
