import Foundation
import SwiftData
import Testing
@testable import FortichePack

@Suite struct ModelTests {
    @Test @MainActor func templateGraphRoundTripsThroughStore() throws {
        let container = try ForticheStore.container(.inMemory)
        let context = container.mainContext

        let template = WorkoutTemplate(name: "5/3/1", sourceText: "raw text")
        let day = TemplateDay(name: "Push A", order: 0)
        let exercise = TemplateExercise(name: "OHP", order: 0, librarySlug: nil, restSeconds: 120)
        let set1 = TemplateSet(order: 0, repsMin: 5, repsMax: 5, weightKg: 60)
        let set2 = TemplateSet(order: 1, repsMin: 8, repsMax: 12)

        exercise.sets = [set1, set2]
        day.exercises = [exercise]
        template.days = [day]
        context.insert(template)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        #expect(fetched.count == 1)
        let sets = try #require(fetched.first?.orderedDays.first?.orderedExercises.first?.orderedSets)
        #expect(sets.map(\.repsMin) == [5, 8])
        #expect(sets[0].weightKg == 60)
        #expect(sets[1].weightKg == nil)
    }

    @Test @MainActor func orderedAccessorsSortRegardlessOfInsertionOrder() throws {
        let container = try ForticheStore.container(.inMemory)
        let context = container.mainContext

        let log = WorkoutLog(title: "Push A", startedAt: .now, host: .watch)
        let exercise = LoggedExercise(name: "Bench", order: 0)
        // Insert out of order on purpose — CloudKit relationships are unordered.
        exercise.sets = [
            LoggedSet(order: 2, reps: 6, weightKg: 90),
            LoggedSet(order: 0, reps: 8, weightKg: 80),
            LoggedSet(order: 1, reps: 8, weightKg: 85),
        ]
        log.exercises = [exercise]
        context.insert(log)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<WorkoutLog>()).first)
        let weights = fetched.orderedExercises.first?.orderedSets.compactMap(\.weightKg)
        #expect(weights == [80, 85, 90])
    }
}
