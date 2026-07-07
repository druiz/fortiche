import SwiftUI
import FortichePack

/// Compact workout status shown in the tab bar's bottom accessory while the
/// full workout view is collapsed — the Music-app mini-player pattern. Tap
/// anywhere to expand back to `LiveWorkoutView`; the workout itself keeps
/// running in the engine regardless of what's on screen.
struct WorkoutMiniBar: View {
    let engine: ActiveWorkoutEngine
    let onExpand: () -> Void
    private let unit = WeightUnit.preferred

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 10) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title3)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                trailingStatus
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Workout in progress: \(title), \(subtitle). Tap to expand.")
    }

    private var state: WorkoutState { engine.state }

    private var currentExercise: ExerciseState? {
        if let current = state.currentExercise, !current.isDone { return current }
        return state.exercises.first { !$0.isDone }
    }

    private var title: String {
        if state.phase == .paused { return "Paused" }
        return currentExercise?.name ?? state.title
    }

    private var subtitle: String {
        guard let exercise = currentExercise, let setIndex = exercise.currentSetIndex else {
            return "All exercises done"
        }
        let set = exercise.sets[setIndex]
        let reps = set.targetRepsMin == 0 ? "AMRAP"
            : set.targetRepsMax > set.targetRepsMin ? "\(set.targetRepsMin)–\(set.targetRepsMax)"
            : "\(set.targetRepsMax)"
        let weight = set.weightKg.map { unit.format(kilograms: $0) } ?? "BW"
        return "Set \(setIndex + 1) of \(exercise.sets.count) · \(reps) × \(weight)"
    }

    @ViewBuilder private var trailingStatus: some View {
        if case .resting(let until) = state.phase {
            // Counts down on its own — no updates needed while collapsed.
            Text(timerInterval: Date.now...until, countsDown: true)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.tint)
        } else if state.phase == .paused {
            Image(systemName: "pause.fill")
                .foregroundStyle(.secondary)
        } else {
            Text("\(state.completedSetCount)/\(state.totalSetCount)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
