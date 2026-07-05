import Foundation
import Observation

/// The workout state machine. Host-agnostic: the same engine runs
/// watch-authoritative (watch session) or phone-authoritative (phone-only).
///
/// - All mutations go through `apply(_:)` / `submit(_:)` — no direct state writes.
/// - Every applied command journals the state to disk so a crash mid-workout
///   restores to the exact set.
/// - `onStateChange` fires after every mutation (used by hosts to echo
///   snapshots to the peer and refresh Live Activities).
@Observable @MainActor
public final class ActiveWorkoutEngine {
    public private(set) var state: WorkoutState
    /// This process's identity — the `origin` on commands it creates.
    public let localHost: WorkoutHost
    /// Called after every state mutation.
    @ObservationIgnored public var onStateChange: ((WorkoutState) -> Void)?
    /// Called for commands submitted on THIS device (not remote ones).
    /// Peer hosts use it to forward envelopes to the authority.
    @ObservationIgnored public var onLocalCommand: ((CommandEnvelope) -> Void)?
    /// Called when a rest phase begins/ends locally (hosts schedule haptics/notifications).
    @ObservationIgnored public var onRestChange: ((_ until: Date?) -> Void)?

    @ObservationIgnored private var nextSeq = 1
    @ObservationIgnored private let journalURL: URL?

    // MARK: Lifecycle

    public init(state: WorkoutState, localHost: WorkoutHost, journalURL: URL? = ActiveWorkoutEngine.defaultJournalURL) {
        self.state = state
        self.localHost = localHost
        self.journalURL = journalURL
        // Resume the sequence counter after recovery — a fresh counter would
        // collide with the restored lastAppliedSeq and dedupe local commands.
        self.nextSeq = (state.lastAppliedSeq[localHost.rawValue] ?? 0) + 1
        journal()
    }

    public static var defaultJournalURL: URL {
        URL.applicationSupportDirectory.appending(path: "active-workout.json")
    }

    /// Restore a crashed/killed session's engine from the journal, if one exists
    /// and wasn't finished.
    public static func recover(localHost: WorkoutHost, journalURL: URL = defaultJournalURL) -> ActiveWorkoutEngine? {
        guard let data = try? Data(contentsOf: journalURL),
              let state = try? JSONDecoder().decode(WorkoutState.self, from: data),
              !state.isFinished
        else { return nil }
        return ActiveWorkoutEngine(state: state, localHost: localHost, journalURL: journalURL)
    }

    public static func clearJournal(at url: URL = defaultJournalURL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Local commands

    /// Create an envelope for a locally-initiated command and apply it.
    /// Returns the envelope so the host can replicate it (peer → authority)
    /// or echo the resulting snapshot (authority → peer).
    @discardableResult
    public func submit(_ command: WorkoutCommand) -> CommandEnvelope {
        let envelope = CommandEnvelope(origin: localHost, seq: nextSeq, command: command)
        nextSeq += 1
        apply(envelope)
        onLocalCommand?(envelope)
        return envelope
    }

    // MARK: Applying

    /// Apply a command envelope (local or remote). Out-of-order/duplicate
    /// envelopes from the same origin are ignored.
    public func apply(_ envelope: CommandEnvelope) {
        let originKey = envelope.origin.rawValue
        if let last = state.lastAppliedSeq[originKey], envelope.seq <= last { return }
        state.lastAppliedSeq[originKey] = envelope.seq

        let wasResting = restDeadline
        run(envelope.command)
        journal()
        if restDeadline != wasResting { onRestChange?(restDeadline) }
        onStateChange?(state)
    }

    /// Replace local state with an authoritative snapshot (peer side only).
    /// Stale snapshots — ones that predate commands this device already sent —
    /// are rejected so optimistic local edits don't visibly roll back.
    public func adopt(snapshot: WorkoutState) -> Bool {
        let localKey = localHost.rawValue
        let acknowledged = snapshot.lastAppliedSeq[localKey] ?? 0
        if acknowledged < nextSeq - 1 { return false }
        let wasResting = restDeadline
        state = snapshot
        journal()
        if restDeadline != wasResting { onRestChange?(restDeadline) }
        onStateChange?(state)
        return true
    }

    // MARK: Derived

    public var restDeadline: Date? {
        if case .resting(let until) = state.phase { return until }
        return nil
    }

    // MARK: Mutation

    private func run(_ command: WorkoutCommand) {
        switch command {
        case .completeSet(let exercise, let set, let reps, let weight):
            guard var target = setAt(exercise, set) else { return }
            target.actualReps = reps
            if let weight { target.weightKg = weight }
            target.completedAt = .now
            target.skipped = false
            put(target, at: exercise, set)
            startRestIfNeeded(afterExercise: exercise)
            advanceIfDone(exercise: exercise)

        case .uncompleteSet(let exercise, let set):
            guard var target = setAt(exercise, set) else { return }
            target.actualReps = nil
            target.completedAt = nil
            put(target, at: exercise, set)

        case .adjustWeight(let exercise, let set, let weight):
            guard var target = setAt(exercise, set) else { return }
            target.weightKg = weight
            put(target, at: exercise, set)

        case .adjustReps(let exercise, let set, let repsMin, let repsMax):
            guard var target = setAt(exercise, set) else { return }
            target.targetRepsMin = max(0, repsMin)
            target.targetRepsMax = max(target.targetRepsMin, repsMax)
            put(target, at: exercise, set)

        case .addSet(let exercise):
            guard state.exercises.indices.contains(exercise) else { return }
            let template = state.exercises[exercise].sets.last
                ?? SetState(targetRepsMin: 8)
            state.exercises[exercise].sets.append(SetState(
                targetRepsMin: template.targetRepsMin,
                targetRepsMax: template.targetRepsMax,
                weightKg: template.weightKg,
                targetRpe: template.targetRpe
            ))

        case .removeLastSet(let exercise):
            guard state.exercises.indices.contains(exercise) else { return }
            if let index = state.exercises[exercise].sets.lastIndex(where: { $0.completedAt == nil }) {
                state.exercises[exercise].sets.remove(at: index)
            }

        case .skipExercise(let exercise):
            guard state.exercises.indices.contains(exercise) else { return }
            state.exercises[exercise].skipped = true
            advanceIfDone(exercise: exercise)

        case .unskipExercise(let exercise):
            guard state.exercises.indices.contains(exercise) else { return }
            state.exercises[exercise].skipped = false

        case .selectExercise(let exercise):
            guard state.exercises.indices.contains(exercise) else { return }
            state.currentExerciseIndex = exercise

        case .skipRest:
            if case .resting = state.phase { state.phase = .active }

        case .adjustRest(let delta):
            if case .resting(let until) = state.phase {
                let adjusted = max(Date.now, until.addingTimeInterval(TimeInterval(delta)))
                state.phase = .resting(until: adjusted)
            }

        case .pause:
            if state.phase != .ended { state.phase = .paused }

        case .resume:
            if state.phase == .paused { state.phase = .active }

        case .end:
            state.phase = .ended
            state.endedAt = .now
        }
    }

    /// The rest phase is UI-level: a deadline. `restExpired()` flips back to
    /// active — hosts call it from their timer tick.
    public func restExpired() {
        if case .resting(let until) = state.phase, until <= .now {
            state.phase = .active
            journal()
            onRestChange?(nil)
            onStateChange?(state)
        }
    }

    private func startRestIfNeeded(afterExercise exercise: Int) {
        guard state.exercises.indices.contains(exercise) else { return }
        let exerciseState = state.exercises[exercise]
        // No rest after the very last set of the workout.
        guard !(exerciseState.isDone && exercise == state.exercises.count - 1) else { return }
        let seconds = exerciseState.restSeconds
        guard seconds > 0 else { return }
        state.phase = .resting(until: .now.addingTimeInterval(TimeInterval(seconds)))
    }

    private func advanceIfDone(exercise: Int) {
        guard state.exercises.indices.contains(exercise),
              state.exercises[exercise].isDone,
              exercise == state.currentExerciseIndex
        else { return }
        if let next = state.exercises[(exercise + 1)...].firstIndex(where: { !$0.isDone }) {
            state.currentExerciseIndex = next
        } else if let anywhere = state.exercises.firstIndex(where: { !$0.isDone }) {
            state.currentExerciseIndex = anywhere
        }
    }

    private func setAt(_ exercise: Int, _ set: Int) -> SetState? {
        guard state.exercises.indices.contains(exercise),
              state.exercises[exercise].sets.indices.contains(set)
        else { return nil }
        return state.exercises[exercise].sets[set]
    }

    private func put(_ setState: SetState, at exercise: Int, _ set: Int) {
        state.exercises[exercise].sets[set] = setState
    }

    private func journal() {
        guard let journalURL else { return }
        if state.isFinished {
            try? FileManager.default.removeItem(at: journalURL)
        } else if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: journalURL, options: .atomic)
        }
    }
}
