import Testing
@testable import FortichePack

/// Fuzzy matching against the real bundled dataset.
@Suite struct ExerciseMatcherTests {
    let library = ExerciseLibrary.shared

    @Test func shorthandAliases() {
        // OHP → an overhead pressing movement (the dataset calls these
        // "shoulder press" / "military press").
        let ohp = library.match(name: "OHP")
        #expect(ohp.contains { $0.name.lowercased().contains("shoulder press") || $0.name.lowercased().contains("military press") })

        // RDL → Romanian deadlift.
        let rdl = library.match(name: "RDL")
        #expect(rdl.contains { $0.name.lowercased().contains("romanian deadlift") })
    }

    @Test func hyphenAndPluralVariants() {
        #expect(library.match(name: "PULL-UP").contains { $0.name.lowercased().contains("pullup") })
        #expect(library.match(name: "push ups").contains { $0.name.lowercased().contains("pushup") })
        #expect(library.match(name: "Squats").contains { $0.name.lowercased().contains("squat") })
    }

    @Test func typoTolerance() {
        #expect(library.match(name: "Bnech Press").contains { $0.name.lowercased().contains("bench press") })
        #expect(library.match(name: "dumbell curl").contains { $0.name.lowercased().contains("dumbbell") })
    }

    @Test func partialNamesRankSensibly() {
        let bench = library.match(name: "Bench Press")
        #expect(!bench.isEmpty)
        // Every candidate should actually be a bench press movement.
        #expect(bench.allSatisfy { $0.name.lowercased().contains("bench press") })
    }

    @Test func garbageStillReturnsNothing() {
        #expect(library.match(name: "xyzzy nonexistent movement").isEmpty)
        #expect(library.match(name: "").isEmpty)
    }

    @Test func confidentMatchIsConservative() {
        // Exact dataset name → confident.
        #expect(ExerciseMatcher.confidentMatch(for: "Pullups", in: library)?.slug == "Pullups")
        // Ambiguous ("Press" alone matches dozens) → nil.
        #expect(ExerciseMatcher.confidentMatch(for: "Press", in: library) == nil)
        // Words not in the dataset ("Doe Press") → nil, stays free-form.
        #expect(ExerciseMatcher.confidentMatch(for: "Doe Press Machine XQ", in: library) == nil)
    }

    @Test func editDistanceBasics() {
        #expect(ExerciseMatcher.editDistance("bench", "bnech") <= 2)
        #expect(ExerciseMatcher.editDistance("press", "press") == 0)
        #expect(ExerciseMatcher.tokensMatch("dumbell", "dumbbell"))
        #expect(!ExerciseMatcher.tokensMatch("row", "raise"))
    }
}
