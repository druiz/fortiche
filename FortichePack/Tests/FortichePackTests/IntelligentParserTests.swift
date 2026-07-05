import Foundation
import Testing
@testable import FortichePack

#if canImport(FoundationModels)
import FoundationModels

/// Integration tests against the real on-device model. They run wherever
/// Apple Intelligence is available (this Mac, a device) and are skipped
/// elsewhere (CI without the model, simulators without host AI).
@Suite(.enabled(if: IntelligentProgramParser.availability == .available))
struct IntelligentParserTests {
    @Test(.timeLimit(.minutes(3))) func parsesSimpleDay() async throws {
        let text = """
        Push day:
        Bench Press 3x5 @ 80kg
        Overhead Press 3x8-12 40 kg
        Dips 3xAMRAP
        """
        let program = try await IntelligentProgramParser().parse(
            text,
            suggestedName: "Test",
            defaultUnit: .kilograms,
            onDay: { _ in }
        )

        #expect(program.days.count == 1)
        let day = try #require(program.days.first)
        #expect(day.exercises.count == 3)

        let bench = try #require(day.exercises.first)
        #expect(bench.name.lowercased().contains("bench"))
        #expect(bench.sets.count == 3)
        #expect(bench.sets.allSatisfy { $0.repsMin == 5 })
        #expect(bench.sets.allSatisfy { $0.weightKg == 80 })

        let ohp = day.exercises[1]
        #expect(ohp.sets.first?.repsMin == 8)
        #expect(ohp.sets.first?.repsMax == 12)

        let dips = day.exercises[2]
        #expect(dips.sets.count == 3)
        #expect(dips.sets.allSatisfy { $0.repsMin == 0 })
    }

    @Test(.timeLimit(.minutes(3))) func convertsPoundsAndPercent() async throws {
        let text = """
        Day 1
        Deadlift 5x3 @ 315 lb
        Squat 3x5 @ 85%
        """
        let program = try await IntelligentProgramParser().parse(
            text,
            suggestedName: "Test",
            defaultUnit: .pounds,
            onDay: { _ in }
        )
        let day = try #require(program.days.first)

        let deadlift = try #require(day.exercises.first)
        let kg = try #require(deadlift.sets.first?.weightKg)
        #expect(abs(kg - WeightUnit.pounds.toKilograms(315)) < 0.5)

        let squat = day.exercises[1]
        #expect(squat.sets.first?.percentOfMax == 85)
        #expect(squat.sets.first?.weightKg == nil)
    }
}
#endif
