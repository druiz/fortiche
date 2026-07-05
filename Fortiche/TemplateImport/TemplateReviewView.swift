import SwiftUI
import FortichePack

/// Post-parse review: everything is editable before the template is saved.
struct TemplateReviewView: View {
    @Bindable var model: TemplateImportModel
    let onSave: () -> Void

    var body: some View {
        List {
            if model.usedFallback {
                Section {
                    Label("Some days were parsed with the basic parser — double-check them.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.parsedDays) { day in
                Section {
                    ForEach(day.exercises) { exercise in
                        NavigationLink {
                            ExerciseReviewView(exercise: exercise) { updated in
                                model.updateExercise(updated, inDay: day.id)
                            }
                        } label: {
                            ExerciseRow(exercise: exercise)
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            model.deleteExercise(day.exercises[offset].id, inDay: day.id)
                        }
                    }
                    Button {
                        _ = model.addExercise(toDay: day.id)
                    } label: {
                        Label("Add Exercise", systemImage: "plus")
                            .font(.subheadline)
                    }
                } header: {
                    HStack {
                        TextField("Day name", text: Binding(
                            get: { day.name },
                            set: { model.updateDayName(day.id, to: $0) }
                        ))
                        .font(.headline)
                        .textCase(nil)
                        Spacer()
                        Button(role: .destructive) {
                            model.deleteDay(day.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section {
                Button {
                    model.addDay()
                } label: {
                    Label("Add Day", systemImage: "plus.rectangle.on.rectangle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onSave()
            } label: {
                Label("Save Program", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
        }
    }
}

/// One exercise line: name, library-match badge, and set summary.
struct ExerciseRow: View {
    let exercise: ParsedExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(exercise.name)
                if exercise.librarySlug != nil {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Matched to exercise library")
                }
            }
            Text(exercise.setSummary(unit: WeightUnit.preferred))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Edit a single exercise: name, library match, rest, and each set.
struct ExerciseReviewView: View {
    @State var exercise: ParsedExercise
    let onChange: (ParsedExercise) -> Void
    @Environment(\.dismiss) private var dismiss
    private let unit = WeightUnit.preferred

    var body: some View {
        Form {
            Section("Exercise") {
                TextField("Name", text: $exercise.name)
                libraryMatchPicker
            }
            Section("Rest between sets") {
                Stepper(
                    value: Binding(
                        get: { exercise.restSeconds ?? 90 },
                        set: { exercise.restSeconds = $0 }
                    ),
                    in: 0...600,
                    step: 15
                ) {
                    Text("\(exercise.restSeconds ?? 90) s")
                }
            }
            Section("Sets") {
                ForEach($exercise.sets) { $set in
                    SetEditorRow(set: $set, unit: unit)
                }
                .onDelete { exercise.sets.remove(atOffsets: $0) }
                Button {
                    let last = exercise.sets.last ?? ParsedSet(repsMin: 8)
                    exercise.sets.append(ParsedSet(
                        repsMin: last.repsMin, repsMax: last.repsMax,
                        weightKg: last.weightKg, percentOfMax: last.percentOfMax, rpe: last.rpe
                    ))
                } label: {
                    Label("Add Set", systemImage: "plus")
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        // Edits commit on back-navigation — there is no explicit save button.
        .onDisappear { onChange(exercise) }
    }

    @ViewBuilder private var libraryMatchPicker: some View {
        let candidates = ExerciseLibrary.shared.match(name: exercise.name, limit: 4)
        if !candidates.isEmpty || exercise.librarySlug != nil {
            Picker("Library match", selection: $exercise.librarySlug) {
                Text("None").tag(String?.none)
                ForEach(candidates) { candidate in
                    Text(candidate.name).tag(String?.some(candidate.slug))
                }
                // Keep the current selection pickable even after a rename
                // pushed it out of the candidate list.
                if let slug = exercise.librarySlug, !candidates.contains(where: { $0.slug == slug }),
                   let current = ExerciseLibrary.shared[slug] {
                    Text(current.name).tag(String?.some(slug))
                }
            }
        }
    }
}

/// Reps + load steppers for one set. Load edits in the display unit (or in
/// %-of-max when the set is percentage-based); zero weight means bodyweight.
struct SetEditorRow: View {
    @Binding var set: ParsedSet
    let unit: WeightUnit

    var body: some View {
        HStack {
            Stepper(value: $set.repsMin, in: 0...100) {
                Text(set.repsMin == 0 ? "AMRAP" : "\(set.repsMin) reps")
                    .frame(minWidth: 70, alignment: .leading)
            }
            .onChange(of: set.repsMin) { _, newValue in
                // Keep the rep range valid: raising the floor drags the ceiling.
                if set.repsMax < newValue { set.repsMax = newValue }
            }
            Divider()
            weightControl
        }
        .font(.callout)
    }

    @ViewBuilder private var weightControl: some View {
        if let percent = set.percentOfMax {
            Stepper(value: Binding(
                get: { percent },
                set: { set.percentOfMax = $0 }
            ), in: 0...100, step: 2.5) {
                Text("\(Int(percent))%")
            }
        } else {
            Stepper(value: Binding(
                get: { set.weightKg.map { unit.fromKilograms($0) } ?? 0 },
                set: { set.weightKg = $0 <= 0 ? nil : unit.toKilograms($0) }
            ), in: 0...1000, step: unit.displayStep) {
                Text(set.weightKg.map { unit.format(kilograms: $0) } ?? "BW")
            }
        }
    }
}

extension ParsedExercise {
    /// "3×5 @ 80 kg" / "3×8–12" / "5, 3, 1 reps" summary for list rows.
    func setSummary(unit: WeightUnit) -> String {
        guard !sets.isEmpty else { return "No sets" }
        let first = sets[0]
        let uniform = sets.allSatisfy {
            $0.repsMin == first.repsMin && $0.repsMax == first.repsMax
                && $0.weightKg == first.weightKg && $0.percentOfMax == first.percentOfMax
        }
        if uniform {
            var reps = first.repsMin == 0 ? "AMRAP" : "\(first.repsMin)"
            if first.repsMax > first.repsMin { reps = "\(first.repsMin)–\(first.repsMax)" }
            var summary = "\(sets.count)×\(reps)"
            if let percent = first.percentOfMax, percent > 0 {
                summary += " @ \(Int(percent))%"
            } else if let kg = first.weightKg, kg > 0 {
                summary += " @ \(unit.format(kilograms: kg))"
            }
            return summary
        }
        return sets.map { $0.repsMin == 0 ? "AMRAP" : "\($0.repsMin)" }.joined(separator: ", ") + " reps"
    }
}
