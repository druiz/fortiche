import SwiftUI
import SwiftData
import FortichePack

/// Live workout on the wrist. Page 1: the current set (one giant action,
/// crown adjusts weight, Double Tap completes). Page 2: exercise progress.
struct WatchLiveWorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    let controller: WatchWorkoutController

    var body: some View {
        if let engine = controller.engine {
            TabView {
                currentPage(engine: engine)
                exerciseList(engine: engine)
                controlsPage(engine: engine)
            }
            .tabViewStyle(.verticalPage)
        }
    }

    @ViewBuilder
    private func currentPage(engine: ActiveWorkoutEngine) -> some View {
        let state = engine.state
        if case .resting(let until) = state.phase {
            WatchRestView(until: until, engine: engine)
        } else if state.phase == .paused {
            VStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").font(.title)
                Button("Resume") { engine.submit(.resume) }
                    .buttonStyle(.borderedProminent)
                    .handGestureShortcut(.primaryAction)
            }
        } else if let exerciseIndex = activeExerciseIndex(state),
                  let setIndex = state.exercises[exerciseIndex].currentSetIndex {
            WatchSetCard(engine: engine, exerciseIndex: exerciseIndex, setIndex: setIndex, heartRate: controller.heartRate)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
                Text("All done!").font(.headline)
                Button("Finish") {
                    Task { await controller.end(in: modelContext) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .handGestureShortcut(.primaryAction)
            }
        }
    }

    /// Exercise for the set card: the current selection while unfinished,
    /// else the first exercise with work left (nil = all done).
    private func activeExerciseIndex(_ state: WorkoutState) -> Int? {
        if let current = state.currentExercise, !current.isDone { return state.currentExerciseIndex }
        return state.exercises.firstIndex { !$0.isDone }
    }

    /// Page 2: progress overview; tapping a row jumps the workout there.
    private func exerciseList(engine: ActiveWorkoutEngine) -> some View {
        List {
            ForEach(Array(engine.state.exercises.enumerated()), id: \.element.id) { index, exercise in
                Button {
                    engine.submit(.selectExercise(index))
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(exercise.name).font(.footnote.bold()).lineLimit(1)
                            Text("\(exercise.sets.count { $0.completedAt != nil })/\(exercise.sets.count) sets")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if exercise.isDone {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle("Exercises")
    }

    /// Page 3: session-level controls (pause/skip/end), kept off the set page
    /// so they can't be fat-fingered mid-set.
    private func controlsPage(engine: ActiveWorkoutEngine) -> some View {
        VStack(spacing: 10) {
            if engine.state.phase == .paused {
                Button("Resume", systemImage: "play.fill") { engine.submit(.resume) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Pause", systemImage: "pause.fill") { engine.submit(.pause) }
                    .buttonStyle(.bordered)
            }
            Button("Skip Exercise", systemImage: "forward.fill") {
                engine.submit(.skipExercise(engine.state.currentExerciseIndex))
            }
            .buttonStyle(.bordered)
            Button("End Workout", systemImage: "flag.checkered", role: .destructive) {
                Task { await controller.end(in: modelContext) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }
}

/// The set you're doing right now. Crown = weight. Double Tap / big button = done.
struct WatchSetCard: View {
    let engine: ActiveWorkoutEngine
    let exerciseIndex: Int
    let setIndex: Int
    let heartRate: Double?

    @State private var crownWeight: Double = 0
    private let unit = WeightUnit.preferred

    private var exercise: ExerciseState { engine.state.exercises[exerciseIndex] }
    private var set: SetState { exercise.sets[setIndex] }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(exercise.name).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                if let heartRate {
                    Label("\(Int(heartRate))", systemImage: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                }
            }

            Text("Set \(setIndex + 1)/\(exercise.sets.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(repsDisplay).font(.title2.bold())
                Text("×").foregroundStyle(.secondary)
                Text(set.weightKg.map { unit.format(kilograms: $0) } ?? "BW")
                    .font(.title2.bold())
                    .foregroundStyle(.tint)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            Button {
                engine.submit(.completeSet(
                    exercise: exerciseIndex,
                    set: setIndex,
                    reps: set.targetRepsMax,
                    weightKg: set.weightKg
                ))
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .handGestureShortcut(.primaryAction)
            .controlSize(.large)
        }
        .padding(.horizontal, 4)
        // Digital Crown adjusts the working weight in display-unit steps —
        // no tiny +/- targets to hit with gloves.
        .focusable(true)
        .digitalCrownRotation(
            $crownWeight,
            from: 0,
            through: 1000,
            by: unit.displayStep,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            crownWeight = set.weightKg.map { unit.fromKilograms($0) } ?? 0
        }
        .onChange(of: set.weightKg) { _, newValue in
            // Engine state can change remotely (phone edit) — follow it.
            crownWeight = newValue.map { unit.fromKilograms($0) } ?? 0
        }
        .onChange(of: crownWeight) { _, newValue in
            let currentDisplay = set.weightKg.map { unit.fromKilograms($0) } ?? 0
            // Half-step threshold breaks the feedback loop between the two
            // onChange handlers and swallows sub-detent crown jitter.
            guard abs(newValue - currentDisplay) >= unit.displayStep / 2 else { return }
            engine.submit(.adjustWeight(
                exercise: exerciseIndex,
                set: setIndex,
                weightKg: newValue <= 0 ? nil : unit.toKilograms(newValue)
            ))
        }
    }

    private var repsDisplay: String {
        if set.targetRepsMin == 0 { return "AMRAP" }
        if set.targetRepsMax > set.targetRepsMin { return "\(set.targetRepsMin)–\(set.targetRepsMax)" }
        return "\(set.targetRepsMax)"
    }
}

/// Rest countdown ring with adjust/skip.
struct WatchRestView: View {
    let until: Date
    let engine: ActiveWorkoutEngine

    var body: some View {
        VStack(spacing: 8) {
            Text("Rest").font(.caption).foregroundStyle(.secondary)
            Text(timerInterval: Date.now...until, countsDown: true)
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .foregroundStyle(.tint)
            HStack {
                Button("+15s") { engine.submit(.adjustRest(deltaSeconds: 15)) }
                    .buttonStyle(.bordered)
                Button("Skip") { engine.submit(.skipRest) }
                    .buttonStyle(.borderedProminent)
                    .handGestureShortcut(.primaryAction)
            }
            .font(.footnote)
        }
    }
}
