import Foundation

/// Fuzzy matching of user-written exercise names against the library.
/// Strategy: expand gym shorthand via the alias table, tokenize, then score
/// candidates by token coverage (with typo/prefix tolerance) and specificity.
public enum ExerciseMatcher {
    /// Common gym shorthand → canonical words. Applied token-wise to queries.
    static let aliases: [String: String] = [
        // The dataset names overhead pressing "shoulder press" / "military press".
        "ohp": "shoulder press",
        "overhead": "shoulder",
        "rdl": "romanian deadlift",
        "sldl": "stiff legged deadlift",
        "cgbp": "close grip bench press",
        "bb": "barbell",
        "db": "dumbbell",
        "kb": "kettlebell",
        "bw": "bodyweight",
        "lat": "latissimus",
        "pullup": "pullups",
        "pull": "pull",
        "chinup": "chin up",
        "pushup": "pushups",
        "gm": "good morning",
        "hs": "hammer strength",
        "bss": "bulgarian split squat",
        "military": "military",
        "dl": "deadlift",
        "bp": "bench press",
        "squats": "squat",
        "ez": "ez",
    ]

    public struct Match: Sendable, Equatable {
        public let exercise: LibraryExercise
        /// 0…1; 1.0 is an exact normalized-name match.
        public let score: Double
    }

    /// Word pairs that are one exercise word ("pull up" ↔ "pullup").
    static let compounds: Set<String> = ["pullup", "pushup", "chinup", "situp", "stepup"]

    /// Tokens after normalization, alias expansion, compound folding, and
    /// singular/plural folding.
    static func tokens(for name: String) -> [String] {
        var raw = ExerciseLibrary.normalize(name)
            .split(separator: " ")
            .flatMap { token -> [Substring] in
                if let expansion = aliases[String(token)] {
                    return expansion.split(separator: " ")
                }
                return [token]
            }
            .map { singularize(String($0)) }

        // Fold "pull up" → "pullup" so hyphen/space variants meet the dataset's
        // concatenated spellings.
        var folded: [String] = []
        var index = 0
        while index < raw.count {
            if index + 1 < raw.count, compounds.contains(raw[index] + raw[index + 1]) {
                folded.append(raw[index] + raw[index + 1])
                index += 2
            } else {
                folded.append(raw[index])
                index += 1
            }
        }
        raw = folded
        return raw
    }

    static func singularize(_ token: String) -> String {
        // "presses" → "press", "curls" → "curl"; keep short words intact.
        if token.count > 4, token.hasSuffix("es"), !token.hasSuffix("ses") {
            return String(token.dropLast(2))
        }
        if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    /// Do two tokens count as the same word? Exact, prefix (≥4 chars), or
    /// one edit apart (≥5 chars — catches "bnech", "dumbell").
    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 4, b.count >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 {
            return editDistance(a, b) <= 1
        }
        return false
    }

    /// Damerau–Levenshtein (optimal string alignment): a transposition like
    /// "bnech" → "bench" counts as one edit.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        var rows = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { rows[i][0] = i }
        for j in 0...b.count { rows[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let substitution = a[i - 1] == b[j - 1] ? 0 : 1
                rows[i][j] = min(
                    rows[i - 1][j] + 1,
                    rows[i][j - 1] + 1,
                    rows[i - 1][j - 1] + substitution
                )
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    rows[i][j] = min(rows[i][j], rows[i - 2][j - 2] + 1)
                }
            }
        }
        return rows[a.count][b.count]
    }

    /// Score a candidate against query tokens.
    static func score(queryTokens: [String], candidate: LibraryExercise) -> Double {
        let candidateTokens = tokens(for: candidate.name)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        if queryTokens == candidateTokens { return 1.0 }

        let matched = queryTokens.filter { query in
            candidateTokens.contains { tokensMatch(query, $0) }
        }
        guard !matched.isEmpty else { return 0 }

        let coverage = Double(matched.count) / Double(queryTokens.count)
        let specificity = Double(matched.count) / Double(candidateTokens.count)
        // Coverage dominates (did we find what the user asked for); specificity
        // breaks ties toward less-decorated names.
        return 0.75 * coverage + 0.25 * specificity
    }

    /// Ranked matches above a floor score.
    public static func matches(
        for name: String,
        in library: ExerciseLibrary,
        limit: Int = 5,
        minimumScore: Double = 0.5
    ) -> [Match] {
        let queryTokens = tokens(for: name)
        guard !queryTokens.isEmpty else { return [] }
        return library.exercises
            .map { Match(exercise: $0, score: score(queryTokens: queryTokens, candidate: $0)) }
            .filter { $0.score >= minimumScore }
            .sorted {
                $0.score != $1.score ? $0.score > $1.score
                    : $0.exercise.name.count < $1.exercise.name.count
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Single confident match for auto-assignment, or nil when it's ambiguous.
    /// Confident = full query coverage AND clearly ahead of the runner-up.
    public static func confidentMatch(for name: String, in library: ExerciseLibrary) -> LibraryExercise? {
        let ranked = matches(for: name, in: library, limit: 3, minimumScore: 0.7)
        guard let top = ranked.first else { return nil }
        if top.score >= 0.999 { return top.exercise }
        // Full coverage required (all the user's words are in the candidate).
        let queryTokens = tokens(for: name)
        let topTokens = tokens(for: top.exercise.name)
        let fullCoverage = queryTokens.allSatisfy { query in
            topTokens.contains { tokensMatch(query, $0) }
        }
        guard fullCoverage else { return nil }
        if ranked.count > 1, ranked[1].score >= top.score - 0.05 { return nil }
        return top.exercise
    }
}

extension ExerciseLibrary {
    /// Ranked fuzzy matches (replaces the old exact/prefix/contains lookup).
    public func fuzzyMatches(name: String, limit: Int = 5) -> [ExerciseMatcher.Match] {
        ExerciseMatcher.matches(for: name, in: self, limit: limit)
    }
}
