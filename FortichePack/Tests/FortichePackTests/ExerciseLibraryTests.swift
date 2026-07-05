import Testing
@testable import FortichePack

@Suite struct ExerciseLibraryTests {
    @Test func bundledDatasetLoads() {
        let library = ExerciseLibrary.shared
        #expect(library.exercises.count > 800)
    }

    @Test func slugsAreUniqueAndResolvable() {
        let library = ExerciseLibrary.shared
        let slugs = library.exercises.map(\.slug)
        #expect(Set(slugs).count == slugs.count)
        for exercise in library.exercises.prefix(20) {
            #expect(library[exercise.slug]?.name == exercise.name)
        }
    }

    @Test func entriesHaveUsableFields() {
        for exercise in ExerciseLibrary.shared.exercises {
            #expect(!exercise.name.isEmpty)
            #expect(!exercise.primaryMuscles.isEmpty || !exercise.secondaryMuscles.isEmpty || exercise.category != nil)
        }
    }

    @Test func nameMatchingFindsCommonLifts() {
        let library = ExerciseLibrary.shared
        #expect(library.match(name: "Barbell Squat").first != nil)
        #expect(library.match(name: "bench press").isEmpty == false)
        // Normalization: punctuation/case insensitive.
        #expect(library.match(name: "PULL-UP").isEmpty == false)
        // Garbage in, empty out — matching is optional by design.
        #expect(library.match(name: "xyzzy nonexistent movement").isEmpty)
    }

    @Test func imageURLsResolve() throws {
        let withImages = try #require(ExerciseLibrary.shared.exercises.first { !$0.images.isEmpty })
        #expect(withImages.imageURLs.first?.host() == "raw.githubusercontent.com")
    }
}
