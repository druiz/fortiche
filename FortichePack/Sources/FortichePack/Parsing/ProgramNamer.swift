import Foundation

/// Derives a program name from its parsed structure when the user doesn't
/// type one — "Push/Pull/Legs" beats "My Program".
public enum ProgramNamer {
    /// Day names that carry no identity ("Day 1", "Monday", …) fall back to a
    /// generic "N-Day Program"; descriptive names are joined ("Push/Pull/Legs").
    public static func suggestName(for days: [ParsedDay]) -> String {
        let meaningful = days.map(shortLabel).filter { !$0.isEmpty }

        // All-generic day names ("Day 1", weekdays) → count-based name.
        guard !meaningful.isEmpty else {
            return days.count <= 1 ? "My Program" : "\(days.count)-Day Program"
        }

        // A single descriptive day names the whole program ("Full Body").
        if days.count == 1 {
            return days[0].name.trimmingCharacters(in: .whitespaces)
        }

        // De-duplicate while keeping order ("Push A"/"Push B" → "Push").
        var seen = Set<String>()
        let unique = meaningful.filter { seen.insert($0).inserted }

        let joined = unique.joined(separator: "/")
        if joined.count <= 28 {
            return joined
        }
        return "\(days.count)-Day Program"
    }

    /// First meaningful word of a day name; empty for generic labels.
    static func shortLabel(_ day: ParsedDay) -> String {
        let name = day.name.trimmingCharacters(in: .whitespaces)
        guard let firstWord = name.split(separator: " ").first.map(String.init) else { return "" }
        let lower = firstWord.lowercased()

        let generic: Set<String> = [
            "day", "week", "workout", "session", "jour",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
        ]
        if generic.contains(lower) || lower.allSatisfy(\.isNumber) { return "" }
        return firstWord.capitalized
    }
}
