import Foundation

/// One entry from the bundled exercise dataset.
///
/// Data: free-exercise-db (https://github.com/yuhonas/free-exercise-db),
/// public domain (Unlicense), itself derived from exercises.json by Ollie
/// Jennings. Credited in the in-app licenses screen — keep that screen in
/// sync if the data source changes.
public struct LibraryExercise: Codable, Sendable, Identifiable, Hashable {
    /// Stable slug, e.g. "Barbell_Squat". Templates reference this.
    public let id: String
    public let name: String
    public let force: String?
    public let level: String?
    public let mechanic: String?
    public let equipment: String?
    public let primaryMuscles: [String]
    public let secondaryMuscles: [String]
    public let instructions: [String]
    public let category: String?
    /// Relative paths; resolve with `imageURLs` (not bundled — fetched lazily).
    public let images: [String]

    public var slug: String { id }

    /// Remote URLs for the exercise photos (lazy-loaded, cached by URLSession).
    public var imageURLs: [URL] {
        images.compactMap {
            URL(string: "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/\($0)")
        }
    }
}

/// Read-only library loaded from the bundled dataset. Deliberately kept out
/// of the CloudKit-synced store: per-device seeding of shared reference data
/// would create duplicates. User-created exercises live in SwiftData instead.
public struct ExerciseLibrary: Sendable {
    public let exercises: [LibraryExercise]
    private let bySlug: [String: LibraryExercise]

    public static let shared: ExerciseLibrary = {
        guard let url = Bundle.module.url(forResource: "exercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let exercises = try? JSONDecoder().decode([LibraryExercise].self, from: data)
        else {
            assertionFailure("Bundled exercise dataset missing or malformed")
            return ExerciseLibrary(exercises: [])
        }
        return ExerciseLibrary(exercises: exercises)
    }()

    public init(exercises: [LibraryExercise]) {
        self.exercises = exercises
        self.bySlug = Dictionary(uniqueKeysWithValues: exercises.map { ($0.slug, $0) })
    }

    public subscript(slug: String) -> LibraryExercise? { bySlug[slug] }

    /// Loose name lookup ("OHP" → overhead press variants, typo-tolerant),
    /// ranked by match quality. See `ExerciseMatcher` for the scoring.
    public func match(name: String, limit: Int = 5) -> [LibraryExercise] {
        ExerciseMatcher.matches(for: name, in: self, limit: limit).map(\.exercise)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
