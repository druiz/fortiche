import SwiftUI
import SwiftData
import FortichePack

/// Looks up the previous session's top set for an exercise, from history.
struct PreviousPerformance {
    let logs: [WorkoutLog]
    func lastTopSet(slug: String?, name: String) -> (reps: Int, weightKg: Double?, date: Date)? {
        WorkoutStats.lastPerformance(ofSlug: slug, name: name, before: .now, in: logs)
    }
}

/// Phone live-workout screen. Gym-glove rules: controls live in the bottom
/// half, one huge primary action, steppers over tiny tap targets, no
/// swipe-only gestures.
struct LiveWorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let controller: any WorkoutHosting
    @State private var showingEndConfirmation = false
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]
    private let unit = WeightUnit.preferred

    var body: some View {
        NavigationStack {
            if let engine = controller.engine {
                content(engine: engine)
                    .navigationTitle(engine.state.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("End", role: .destructive) { showingEndConfirmation = true }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            if engine.state.phase == .paused {
                                Button("Resume", systemImage: "play.fill") { engine.submit(.resume) }
                            } else {
                                Button("Pause", systemImage: "pause") { engine.submit(.pause) }
                            }
                        }
                    }
                    // Workouts under 3 minutes are discarded entirely (no log,
                    // no HealthKit sample) — the alert makes the outcome
                    // explicit before the user commits. Saving is the normal
                    // path, so only the discard action is styled destructive.
                    .alert(
                        engine.state.qualifiesForSaving ? "End Workout?" : "Discard Workout?",
                        isPresented: $showingEndConfirmation
                    ) {
                        Button(
                            engine.state.qualifiesForSaving ? "End & Save" : "Discard",
                            role: engine.state.qualifiesForSaving ? nil : .destructive
                        ) {
                            Task {
                                await controller.end(in: modelContext)
                                dismiss()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            engine.state.qualifiesForSaving
                                ? "It will be saved to History and Apple Health."
                                : "Workouts under 3 minutes aren't saved."
                        )
                    }
            } else {
                // Engine cleared (workout ended elsewhere).
                Color.clear.onAppear { dismiss() }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func content(engine: ActiveWorkoutEngine) -> some View {
        let state = engine.state
        VStack(spacing: 0) {
            exerciseProgressList(engine: engine)

            Spacer(minLength: 0)

            if case .resting(let until) = state.phase {
                RestBar(until: until, engine: engine)
            }

            if state.phase == .paused {
                pausedCard
            } else if let exerciseIndex = currentExerciseIndex(state),
                      let setIndex = state.exercises[exerciseIndex].currentSetIndex {
                CurrentSetCard(
                    engine: engine,
                    exerciseIndex: exerciseIndex,
                    setIndex: setIndex,
                    unit: unit,
                    previous: PreviousPerformance(logs: logs)
                )
            } else {
                allDoneCard
            }
        }
    }

    /// The exercise the set card should show: the user's selection while it
    /// has work left, otherwise the first unfinished exercise (nil = all done).
    private func currentExerciseIndex(_ state: WorkoutState) -> Int? {
        if let current = state.currentExercise, !current.isDone {
            return state.currentExerciseIndex
        }
        return state.exercises.firstIndex { !$0.isDone }
    }

    /// Top-half overview: tap a row to jump to that exercise, swipe to
    /// skip/unskip.
    private func exerciseProgressList(engine: ActiveWorkoutEngine) -> some View {
        List {
            ForEach(Array(engine.state.exercises.enumerated()), id: \.element.id) { index, exercise in
                Button {
                    engine.submit(.selectExercise(index))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .font(index == engine.state.currentExerciseIndex ? .headline : .body)
                            Text(setsSummary(exercise))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if exercise.isDone {
                            Image(systemName: exercise.skipped ? "arrow.uturn.forward.circle" : "checkmark.circle.fill")
                                .foregroundStyle(exercise.skipped ? Color.secondary : .green)
                        } else if index == engine.state.currentExerciseIndex {
                            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing) {
                    if !exercise.isDone {
                        Button("Skip") { engine.submit(.skipExercise(index)) }.tint(.orange)
                    } else if exercise.skipped {
                        Button("Unskip") { engine.submit(.unskipExercise(index)) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func setsSummary(_ exercise: ExerciseState) -> String {
        let done = exercise.sets.count { $0.completedAt != nil }
        return "\(done)/\(exercise.sets.count) sets · rest \(exercise.restSeconds)s"
    }

    private var pausedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "pause.circle.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("Paused").font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(.thinMaterial)
    }

    private var allDoneCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
            Text("All exercises done").font(.headline)
            Button {
                showingEndConfirmation = true
            } label: {
                Label("Finish Workout", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding(.vertical, 24)
        .background(.thinMaterial)
    }
}

/// The big bottom card for the set you're doing right now.
struct CurrentSetCard: View {
    let engine: ActiveWorkoutEngine
    let exerciseIndex: Int
    let setIndex: Int
    let unit: WeightUnit
    var previous: PreviousPerformance?

    private var exercise: ExerciseState { engine.state.exercises[exerciseIndex] }
    private var set: SetState { exercise.sets[setIndex] }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(exercise.name).font(.title3.bold())
                    Text("Set \(setIndex + 1) of \(exercise.sets.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let ghost = ghostText {
                        Label(ghost, systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("Add set", systemImage: "plus") { engine.submit(.addSet(exercise: exerciseIndex)) }
                    Button("Remove set", systemImage: "minus") { engine.submit(.removeLastSet(exercise: exerciseIndex)) }
                    Button("Skip exercise", systemImage: "forward") { engine.submit(.skipExercise(exerciseIndex)) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title2)
                }
            }

            HStack(spacing: 12) {
                AdjusterView(
                    label: "Reps",
                    value: "\(repsDisplay)",
                    decrease: { adjustReps(-1) },
                    increase: { adjustReps(1) }
                )
                AdjusterView(
                    label: "Weight",
                    value: set.weightKg.map { unit.format(kilograms: $0) } ?? "BW",
                    decrease: { adjustWeight(-unit.displayStep) },
                    increase: { adjustWeight(unit.displayStep) }
                )
            }

            Button {
                engine.submit(.completeSet(
                    exercise: exerciseIndex,
                    set: setIndex,
                    reps: set.targetRepsMax,
                    weightKg: set.weightKg
                ))
            } label: {
                Text("Done — \(repsDisplay) × \(set.weightKg.map { unit.format(kilograms: $0) } ?? "BW")")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
    }

    private var repsDisplay: String {
        if set.targetRepsMin == 0 { return "AMRAP" }
        if set.targetRepsMax > set.targetRepsMin { return "\(set.targetRepsMin)–\(set.targetRepsMax)" }
        return "\(set.targetRepsMax)"
    }

    /// "Last: 8 × 80 kg" — what this exercise looked like last session, so the
    /// user can judge today's load without leaving the card.
    private var ghostText: String? {
        guard let last = previous?.lastTopSet(slug: exercise.librarySlug, name: exercise.name) else { return nil }
        let weight = last.weightKg.map { unit.format(kilograms: $0) } ?? "BW"
        return "Last: \(last.reps) × \(weight)"
    }

    private func adjustReps(_ delta: Int) {
        let target = max(0, set.targetRepsMax + delta)
        engine.submit(.adjustReps(exercise: exerciseIndex, set: setIndex, repsMin: target, repsMax: target))
    }

    /// Steps in display units, converts back to canonical kilograms; stepping
    /// down to zero means bodyweight (nil).
    private func adjustWeight(_ deltaDisplay: Double) {
        let current = set.weightKg.map { unit.fromKilograms($0) } ?? 0
        let next = max(0, current + deltaDisplay)
        engine.submit(.adjustWeight(
            exercise: exerciseIndex,
            set: setIndex,
            weightKg: next == 0 ? nil : unit.toKilograms(next)
        ))
    }
}

/// Big-target stepper: label, value, and fat +/− buttons.
struct AdjusterView: View {
    let label: String
    let value: String
    let decrease: () -> Void
    let increase: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Button(action: decrease) {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 40)
                }
                Text(value)
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 64)
                Button(action: increase) {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 40)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Countdown strip shown above the set card while resting, with extend/skip.
struct RestBar: View {
    let until: Date
    let engine: ActiveWorkoutEngine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
            Text(timerInterval: Date.now...until, countsDown: true)
                .font(.title3.bold().monospacedDigit())
            Spacer()
            Button("+15s") { engine.submit(.adjustRest(deltaSeconds: 15)) }
                .buttonStyle(.bordered)
            Button("Skip") { engine.submit(.skipRest) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.15))
    }
}
