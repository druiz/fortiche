import Foundation
import Testing
@testable import FortichePack

@MainActor
@Suite struct EngineTests {
    func makeEngine(journal: URL? = nil) -> ActiveWorkoutEngine {
        let state = WorkoutState(
            title: "Push A",
            host: .phone,
            startedAt: .now,
            exercises: [
                ExerciseState(name: "Bench", restSeconds: 90, sets: [
                    SetState(targetRepsMin: 5, weightKg: 80),
                    SetState(targetRepsMin: 5, weightKg: 80),
                ]),
                ExerciseState(name: "OHP", restSeconds: 120, sets: [
                    SetState(targetRepsMin: 8, targetRepsMax: 12, weightKg: 40),
                ]),
            ]
        )
        return ActiveWorkoutEngine(state: state, localHost: .phone, journalURL: journal)
    }

    @Test func completeSetStartsRestAndRecordsActuals() {
        let engine = makeEngine()
        engine.submit(.completeSet(exercise: 0, set: 0, reps: 5, weightKg: 82.5))

        let set = engine.state.exercises[0].sets[0]
        #expect(set.actualReps == 5)
        #expect(set.weightKg == 82.5)
        #expect(set.completedAt != nil)
        guard case .resting(let until) = engine.state.phase else {
            Issue.record("expected resting phase")
            return
        }
        #expect(until.timeIntervalSinceNow > 85 && until.timeIntervalSinceNow <= 90)
    }

    @Test func finishingExerciseAdvancesToNext() {
        let engine = makeEngine()
        engine.submit(.completeSet(exercise: 0, set: 0, reps: 5, weightKg: nil))
        engine.submit(.completeSet(exercise: 0, set: 1, reps: 5, weightKg: nil))
        #expect(engine.state.currentExerciseIndex == 1)
    }

    @Test func lastSetOfWorkoutStartsNoRest() {
        let engine = makeEngine()
        engine.submit(.skipExercise(0))
        engine.submit(.completeSet(exercise: 1, set: 0, reps: 10, weightKg: nil))
        #expect(engine.state.phase == .active)
        #expect(engine.state.exercises[1].isDone)
    }

    @Test func addAndRemoveSetCloneLastPrescription() {
        let engine = makeEngine()
        engine.submit(.addSet(exercise: 0))
        #expect(engine.state.exercises[0].sets.count == 3)
        #expect(engine.state.exercises[0].sets[2].weightKg == 80)
        engine.submit(.removeLastSet(exercise: 0))
        #expect(engine.state.exercises[0].sets.count == 2)
        // Completed sets are never removed.
        engine.submit(.completeSet(exercise: 0, set: 0, reps: 5, weightKg: nil))
        engine.submit(.completeSet(exercise: 0, set: 1, reps: 5, weightKg: nil))
        engine.submit(.removeLastSet(exercise: 0))
        #expect(engine.state.exercises[0].sets.count == 2)
    }

    @Test func restAdjustAndSkip() {
        let engine = makeEngine()
        engine.submit(.completeSet(exercise: 0, set: 0, reps: 5, weightKg: nil))
        engine.submit(.adjustRest(deltaSeconds: 30))
        guard case .resting(let until) = engine.state.phase else {
            Issue.record("expected resting")
            return
        }
        #expect(until.timeIntervalSinceNow > 115)
        engine.submit(.skipRest)
        #expect(engine.state.phase == .active)
    }

    @Test func duplicateAndStaleEnvelopesAreIgnored() {
        let engine = makeEngine()
        let envelope = CommandEnvelope(origin: .watch, seq: 5, command: .adjustWeight(exercise: 0, set: 0, weightKg: 100))
        engine.apply(envelope)
        #expect(engine.state.exercises[0].sets[0].weightKg == 100)

        // Same-seq duplicate and older seq must be no-ops.
        engine.apply(CommandEnvelope(origin: .watch, seq: 5, command: .adjustWeight(exercise: 0, set: 0, weightKg: 55)))
        engine.apply(CommandEnvelope(origin: .watch, seq: 4, command: .adjustWeight(exercise: 0, set: 0, weightKg: 60)))
        #expect(engine.state.exercises[0].sets[0].weightKg == 100)
    }

    @Test func staleSnapshotsAreRejectedFreshOnesAdopted() {
        let engine = makeEngine()
        // Local optimistic command (phone seq 1) not yet acknowledged:
        engine.submit(.adjustWeight(exercise: 0, set: 0, weightKg: 90))

        var staleSnapshot = engine.state
        staleSnapshot.lastAppliedSeq[WorkoutHost.phone.rawValue] = 0
        staleSnapshot.exercises[0].sets[0].weightKg = 80
        #expect(engine.adopt(snapshot: staleSnapshot) == false)
        #expect(engine.state.exercises[0].sets[0].weightKg == 90)

        var freshSnapshot = staleSnapshot
        freshSnapshot.lastAppliedSeq[WorkoutHost.phone.rawValue] = 1
        freshSnapshot.exercises[0].sets[0].weightKg = 92.5
        #expect(engine.adopt(snapshot: freshSnapshot) == true)
        #expect(engine.state.exercises[0].sets[0].weightKg == 92.5)
    }

    @Test func journalRoundTripRestoresMidWorkoutState() throws {
        let journal = URL.temporaryDirectory.appending(path: "engine-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journal) }

        let engine = makeEngine(journal: journal)
        engine.submit(.completeSet(exercise: 0, set: 0, reps: 5, weightKg: 85))
        engine.submit(.adjustReps(exercise: 0, set: 1, repsMin: 3, repsMax: 3))

        let recovered = try #require(ActiveWorkoutEngine.recover(localHost: .phone, journalURL: journal))
        #expect(recovered.state.exercises[0].sets[0].actualReps == 5)
        #expect(recovered.state.exercises[0].sets[1].targetRepsMin == 3)

        // Ending the workout clears the journal — nothing to recover next launch.
        recovered.submit(.end)
        #expect(ActiveWorkoutEngine.recover(localHost: .phone, journalURL: journal) == nil)
    }

    @Test func endProducesLogWithOnlyCompletedWork() {
        let engine = makeEngine()
        engine.submit(.completeSet(exercise: 0, set: 0, reps: 5, weightKg: 80))
        engine.submit(.end)

        let log = engine.state.makeLog()
        #expect(log.endedAt != nil)
        #expect(log.orderedExercises.count == 1)
        #expect(log.orderedExercises[0].orderedSets.count == 1)
        #expect(log.orderedExercises[0].orderedSets[0].reps == 5)
    }

    @Test func snapshotMessageRoundTripsThroughWire() throws {
        let engine = makeEngine()
        engine.submit(.completeSet(exercise: 0, set: 0, reps: 5, weightKg: 80))
        let data = try SyncMessage.snapshot(engine.state).encoded()
        let decoded = try SyncMessage.decode(data)
        #expect(decoded == .snapshot(engine.state))
    }
}
