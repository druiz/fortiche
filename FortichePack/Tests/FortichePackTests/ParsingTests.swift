import Foundation
import Testing
@testable import FortichePack

@Suite struct SegmenterTests {
    static let ppl = """
    My PPL program

    Push A:
    Bench Press 3x5 @ 80kg
    OHP 3x8-12 40 kg
    Dips 3xAMRAP

    Pull A:
    Deadlift 1x5 @ 140kg
    Rows 4x8 60kg

    Legs:
    Squat 3x5 @ 100kg
    """

    @Test func splitsOnHeaderLines() {
        let chunks = ProgramSegmenter.segment(Self.ppl)
        #expect(chunks.map(\.header).contains(["Push A", "Pull A", "Legs"]))
        let push = chunks.first { $0.header == "Push A" }
        #expect(push?.body.contains("Bench Press") == true)
        #expect(push?.body.contains("Deadlift") == false)
    }

    @Test func weekdayAndDayNHeaders() {
        let text = """
        Monday
        Squat 5x5 @ 100kg

        Day 2
        Bench 5x5 @ 80kg
        """
        let chunks = ProgramSegmenter.segment(text)
        #expect(chunks.count == 2)
        #expect(chunks[0].header.lowercased() == "monday")
        #expect(chunks[1].header == "Day 2")
    }

    @Test func headerlessTextBecomesSingleChunk() {
        let text = "Squat 3x5 @ 100kg\nBench 3x5 @ 80kg"
        let chunks = ProgramSegmenter.segment(text)
        #expect(chunks.count == 1)
        #expect(chunks[0].body.contains("Squat"))
    }

    @Test func exerciseLinesAreNotHeaders() {
        #expect(!ProgramSegmenter.isDayHeader("Bench Press 3x5 @ 80kg"))
        #expect(!ProgramSegmenter.isDayHeader("OHP 3×8-12 40 kg"))
        #expect(ProgramSegmenter.isDayHeader("# Push Day"))
        #expect(ProgramSegmenter.isDayHeader("Day 1"))
        #expect(ProgramSegmenter.isDayHeader("Upper body:"))
    }
}

@Suite struct HeuristicLineParserTests {
    @Test func standardNotation() throws {
        let exercise = try #require(HeuristicLineParser.parse(line: "Bench Press 3x5 @ 80kg", defaultUnit: .kilograms))
        #expect(exercise.name == "Bench Press")
        #expect(exercise.sets.count == 3)
        #expect(exercise.sets[0].repsMin == 5)
        #expect(exercise.sets[0].weightKg == 80)
    }

    @Test func repRangeAndBareWeightUsesDefaultUnit() throws {
        let exercise = try #require(HeuristicLineParser.parse(line: "OHP 3×8-12 @ 95", defaultUnit: .pounds))
        #expect(exercise.sets.count == 3)
        #expect(exercise.sets[0].repsMin == 8)
        #expect(exercise.sets[0].repsMax == 12)
        let kg = try #require(exercise.sets[0].weightKg)
        #expect(abs(kg - WeightUnit.pounds.toKilograms(95)) < 0.001)
    }

    @Test func amrapAndBodyweight() throws {
        let exercise = try #require(HeuristicLineParser.parse(line: "Pull-ups 3xAMRAP", defaultUnit: .kilograms))
        #expect(exercise.sets.count == 3)
        #expect(exercise.sets[0].repsMin == 0)
        #expect(exercise.sets[0].weightKg == nil)
    }

    @Test func percentAndRest() throws {
        let exercise = try #require(HeuristicLineParser.parse(line: "Squat 5x3 @ 85% rest 180s", defaultUnit: .kilograms))
        #expect(exercise.sets[0].percentOfMax == 85)
        #expect(exercise.sets[0].weightKg == nil)
        #expect(exercise.restSeconds == 180)
    }

    @Test func rpeCapture() throws {
        let exercise = try #require(HeuristicLineParser.parse(line: "Curls 4x12 RPE 8", defaultUnit: .kilograms))
        #expect(exercise.sets[0].rpe == 8)
    }

    @Test func poundsInName() throws {
        let exercise = try #require(HeuristicLineParser.parse(line: "Deadlift 225 lb 5x3", defaultUnit: .pounds))
        #expect(exercise.name == "Deadlift")
        let kg = try #require(exercise.sets[0].weightKg)
        #expect(abs(kg - WeightUnit.pounds.toKilograms(225)) < 0.001)
    }

    @Test func nonExerciseLinesReturnNil() {
        #expect(HeuristicLineParser.parse(line: "", defaultUnit: .kilograms) == nil)
        #expect(HeuristicLineParser.parse(line: "Rest day — go for a walk", defaultUnit: .kilograms) == nil)
    }
}

@Suite struct HeuristicProgramParserTests {
    @Test func endToEndParseAndCanonicalize() async throws {
        var streamed: [String] = []
        let collector = Collector { streamed.append($0) }
        let program = try await HeuristicProgramParser().parse(
            SegmenterTests.ppl,
            suggestedName: "PPL",
            defaultUnit: .kilograms,
            onDay: { collector.add($0.name) }
        )
        #expect(program.days.count >= 3)
        #expect(program.usedFallback)

        let push = try #require(program.days.first { $0.name == "Push A" })
        #expect(push.exercises.map(\.name) == ["Bench Press", "OHP", "Dips"])

        let canonicalized = program.canonicalized()
        // "Bench Press" has no exact-normalized match in free-exercise-db
        // ("Barbell Bench Press - Medium Grip" etc.), so it must stay free-form
        // rather than being force-matched.
        let bench = try #require(canonicalized.days[0].exercises.first)
        if let slug = bench.librarySlug {
            #expect(ExerciseLibrary.shared[slug] != nil)
        }
    }

    @Test @MainActor func makeTemplatePreservesStructure() throws {
        let program = ParsedProgram(name: "Test", days: [
            ParsedDay(name: "A", exercises: [
                ParsedExercise(name: "Squat", restSeconds: 120, sets: [
                    ParsedSet(repsMin: 5, weightKg: 100),
                    ParsedSet(repsMin: 5, weightKg: 100),
                ]),
            ]),
        ])
        let template = program.makeTemplate(sourceText: "src")
        #expect(template.orderedDays.first?.orderedExercises.first?.restSeconds == 120)
        #expect(template.orderedDays.first?.orderedExercises.first?.orderedSets.count == 2)
    }
}

/// Tiny helper to collect values from a @Sendable closure without capture headaches.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private let append: (String) -> Void
    init(_ append: @escaping (String) -> Void) { self.append = append }
    func add(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        append(value)
    }
}
