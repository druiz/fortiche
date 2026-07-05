import Foundation
import Testing
@testable import FortichePack

@Suite struct ProgramNamerTests {
    func days(_ names: [String]) -> [ParsedDay] {
        names.map { ParsedDay(name: $0, exercises: []) }
    }

    @Test func descriptiveDayNamesJoin() {
        #expect(ProgramNamer.suggestName(for: days(["Push A", "Pull A", "Legs"])) == "Push/Pull/Legs")
        #expect(ProgramNamer.suggestName(for: days(["Upper", "Lower"])) == "Upper/Lower")
    }

    @Test func duplicateLabelsCollapse() {
        #expect(ProgramNamer.suggestName(for: days(["Push A", "Push B", "Legs"])) == "Push/Legs")
    }

    @Test func genericNamesFallBackToCount() {
        #expect(ProgramNamer.suggestName(for: days(["Day 1", "Day 2", "Day 3"])) == "3-Day Program")
        #expect(ProgramNamer.suggestName(for: days(["Monday", "Wednesday"])) == "2-Day Program")
    }

    @Test func singleDayEdgeCases() {
        #expect(ProgramNamer.suggestName(for: days(["Full Body"])) == "Full Body")
        #expect(ProgramNamer.suggestName(for: days(["Day 1"])) == "My Program")
        #expect(ProgramNamer.suggestName(for: []) == "My Program")
    }

    @Test func overlongJoinFallsBackToCount() {
        let longNames = days(["Hypertrophy Focus", "Maximal Strength", "Explosive Power", "Conditioning"])
        #expect(ProgramNamer.suggestName(for: longNames) == "4-Day Program")
    }
}

@MainActor
@Suite struct WorkoutSavingRuleTests {
    @Test func shortWorkoutsDoNotQualify() {
        var state = WorkoutState(title: "T", host: .phone, startedAt: .now, exercises: [])
        state.endedAt = state.startedAt.addingTimeInterval(120)
        #expect(!state.qualifiesForSaving)

        state.endedAt = state.startedAt.addingTimeInterval(200)
        #expect(state.qualifiesForSaving)
    }

    @Test func unendedWorkoutUsesNow() {
        let state = WorkoutState(
            title: "T",
            host: .phone,
            startedAt: Date(timeIntervalSinceNow: -600),
            exercises: []
        )
        #expect(state.qualifiesForSaving)
    }
}
