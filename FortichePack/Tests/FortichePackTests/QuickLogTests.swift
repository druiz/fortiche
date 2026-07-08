import Foundation
import SwiftData
import Testing
@testable import FortichePack

@Suite struct QuickLogTests {
    @Test func quickEntryBuildsCompletedState() {
        let state = WorkoutState.quickEntry(
            exerciseName: "Crunches", librarySlug: "3_4_Sit-Up",
            sets: 3, reps: 20, weightKg: nil
        )
        #expect(state.kind == .quick)
        #expect(state.phase == .ended)
        #expect(state.endedAt != nil)
        #expect(state.exercises.count == 1)
        #expect(state.exercises[0].sets.count == 3)
        #expect(state.exercises[0].sets.allSatisfy { $0.completedAt != nil && $0.actualReps == 20 })
        // Estimated duration: 45s/set, floor 60s — and it must beat the
        // sub-3-minute rule check being irrelevant (quick logs bypass it).
        let duration = state.endedAt!.timeIntervalSince(state.startedAt)
        #expect(duration == 3 * 45)
    }

    @Test func quickEntryDurationHasFloor() {
        let state = WorkoutState.quickEntry(
            exerciseName: "Pull Ups", librarySlug: nil, sets: 1, reps: 10, weightKg: nil
        )
        #expect(state.endedAt!.timeIntervalSince(state.startedAt) == 60)
    }

    @Test @MainActor func quickEntryMakesLogWithKind() throws {
        let container = try ForticheStore.container(.inMemory)
        let context = container.mainContext

        let state = WorkoutState.quickEntry(
            exerciseName: "Curls", librarySlug: nil, sets: 2, reps: 12, weightKg: 15
        )
        let log = state.makeLog()
        context.insert(log)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<WorkoutLog>()).first)
        #expect(fetched.kind == .quick)
        #expect(fetched.title == "Curls")
        #expect(fetched.orderedExercises.first?.orderedSets.count == 2)
        #expect(fetched.orderedExercises.first?.orderedSets.first?.weightKg == 15)
        // Quick logs count toward volume like any other workout.
        #expect(fetched.totalVolumeKg == 2 * 12 * 15)
    }

    @Test func oldJournalsWithoutKindStillDecode() throws {
        // Simulates a pre-quick-log journal/snapshot: encode, strip kindRaw,
        // decode — the field is optional precisely for this.
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
