import Foundation
import SwiftData
import Testing
@testable import FortichePack

@Suite struct QuickWorkoutTests {
    @Test func adHocStartIsLiveAndUncompleted() {
        let state = WorkoutState.adHocStart(
            exerciseName: "Crunches", librarySlug: "3_4_Sit-Up",
            sets: 3, reps: 20, weightKg: nil
        )
        #expect(state.kind == .quick)
        #expect(state.phase == .active)
        #expect(state.endedAt == nil)
        #expect(state.exercises.count == 1)
        #expect(state.exercises[0].sets.count == 3)
        // Live session: nothing is completed yet — sets are targets.
        #expect(state.exercises[0].sets.allSatisfy { $0.completedAt == nil })
        #expect(state.exercises[0].sets.allSatisfy { $0.targetRepsMin == 20 })
    }

    @Test @MainActor func adHocSetsFlowThroughEngineAndLog() {
        let engine = ActiveWorkoutEngine(
            state: .adHocStart(exerciseName: "Curls", librarySlug: nil, sets: 2, reps: 12, weightKg: 15),
            localHost: .phone,
            journalURL: nil
        )
        engine.completeCurrentSet()
        engine.completeCurrentSet()
        engine.submit(.end)

        let log = engine.state.makeLog()
        #expect(log.kind == .quick)
        #expect(log.title == "Curls")
        #expect(log.orderedExercises.first?.orderedSets.count == 2)
        #expect(log.totalVolumeKg == 2 * 12 * 15)
    }

    @Test func shortWorkoutWithCompletedSetsQualifies() {
        // 90 seconds of crunches with logged sets is deliberate — keep it.
        var state = WorkoutState.adHocStart(
            exerciseName: "Crunches", librarySlug: nil, sets: 1, reps: 20, weightKg: nil
        )
        state.exercises[0].sets[0].actualReps = 20
        state.exercises[0].sets[0].completedAt = .now
        state.endedAt = state.startedAt.addingTimeInterval(90)
        #expect(state.qualifiesForSaving)
    }

    @Test func shortEmptyWorkoutStillDiscards() {
        // The accidental-start guard is unchanged for empty sessions.
        var state = WorkoutState(title: "Push A", host: .phone, startedAt: .now, exercises: [])
        state.endedAt = state.startedAt.addingTimeInterval(90)
        #expect(!state.qualifiesForSaving)

        state.endedAt = state.startedAt.addingTimeInterval(200)
        #expect(state.qualifiesForSaving)
    }

    @Test func oldJournalsWithoutKindStillDecode() throws {
        // Simulates a pre-quick-workout journal/snapshot: encode, strip
        // kindRaw, decode — the field is optional precisely for this.
        let state = WorkoutState(title: "Push A", host: .watch, startedAt: .now, exercises: [])
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        json.removeValue(forKey: "kindRaw")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WorkoutState.self, from: stripped)
        #expect(decoded.kind == .session)
    }
}
