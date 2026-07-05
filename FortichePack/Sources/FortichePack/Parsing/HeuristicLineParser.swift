import Foundation

/// Deterministic exercise-line parser. Serves as the always-available fallback
/// when Apple Intelligence is unavailable, and as the reference implementation
/// for tests. Handles the common notations:
///
///   "Squat 3x5 @ 100kg"        "Bench Press 5×8-12 80 kg"
///   "OHP 3x8 @ 65% rest 120s"  "Pull-ups 3xAMRAP"
///   "Deadlift 225 lb 5x3"      "Curls 4x12 RPE 8"
public enum HeuristicLineParser {
    /// Parse one line; nil when the line doesn't look like an exercise.
    public static func parse(line rawLine: String, defaultUnit: WeightUnit) -> ParsedExercise? {
        let line = rawLine
            .replacingOccurrences(of: "×", with: "x")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t"))
        guard !line.isEmpty else { return nil }

        // Sets x reps: "3x5", "3 x 8-12", "3xAMRAP"
        guard let setsReps = line.range(of: #"(\d+)\s*x\s*(\d+(?:\s*[-–]\s*\d+)?|amrap)"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let match = String(line[setsReps])
        let parts = match.lowercased().components(separatedBy: "x")
        let setCount = Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? 1

        var repsMin = 0
        var repsMax = 0
        let repsPart = parts[1].trimmingCharacters(in: .whitespaces)
        if repsPart != "amrap" {
            let bounds = repsPart.components(separatedBy: CharacterSet(charactersIn: "-–"))
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            repsMin = bounds.first ?? 0
            repsMax = bounds.count > 1 ? bounds[1] : repsMin
        }

        // Name: whatever precedes the sets-x-reps token (or follows, for "225 lb 5x3" style put name first anyway).
        var name = String(line[line.startIndex..<setsReps.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: ":-–— \t"))
        if name.isEmpty {
            name = String(line[setsReps.upperBound...])
                .replacingOccurrences(of: #"[@0-9].*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":-–— \t"))
        }
        // Strip trailing weight tokens accidentally captured in the name ("Deadlift 225 lb").
        var weightFromName: (Double, WeightUnit)?
        if let weightInName = name.range(of: #"(\d+(?:[.,]\d+)?)\s*(kg|kgs|lb|lbs|#)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            weightFromName = parseWeight(String(name[weightInName]), defaultUnit: defaultUnit)
            name = String(name[name.startIndex..<weightInName.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty else { return nil }

        let tail = String(line[setsReps.upperBound...])

        // Weight: "@ 100kg", "@100", "80 kg", "225lb", "@ 65%"
        var weightKg: Double?
        var percent: Double?
        if let percentRange = tail.range(of: #"(\d+(?:[.,]\d+)?)\s*%"#, options: .regularExpression) {
            percent = Double(numeric(String(tail[percentRange]).dropLast()))
        } else if let weight = weightFromName {
            weightKg = weight.1.toKilograms(weight.0)
        } else if let weightRange = tail.range(of: #"@?\s*(\d+(?:[.,]\d+)?)\s*(kg|kgs|lb|lbs|#)?\b"#, options: [.regularExpression, .caseInsensitive]),
                  tail[weightRange].contains(where: \.isNumber) {
            let token = String(tail[weightRange])
            // Bare numbers only count as weight when preceded by "@" (avoids eating "rest 90").
            if token.contains("@") || token.lowercased().contains("kg") || token.lowercased().contains("lb") || token.contains("#") {
                if let parsed = parseWeight(token, defaultUnit: defaultUnit) {
                    weightKg = parsed.1.toKilograms(parsed.0)
                }
            }
        }

        // RPE
        var rpe: Double?
        if let rpeRange = tail.range(of: #"rpe\s*(\d+(?:[.,]\d+)?)"#, options: [.regularExpression, .caseInsensitive]) {
            rpe = Double(numeric(String(tail[rpeRange]).dropFirst(3)))
        }

        // Rest: "rest 90s", "rest 2min", "R90"
        var restSeconds: Int?
        if let restRange = tail.range(of: #"(rest|repos|r)\s*:?\s*(\d+)\s*(s|sec|m|min)?"#, options: [.regularExpression, .caseInsensitive]) {
            let token = String(tail[restRange]).lowercased()
            if let value = Int(numeric(token)) {
                restSeconds = token.contains("m") ? value * 60 : value
            }
        }

        let set = ParsedSet(repsMin: repsMin, repsMax: repsMax, weightKg: weightKg, percentOfMax: percent, rpe: rpe)
        return ParsedExercise(
            name: name,
            restSeconds: restSeconds,
            sets: Array(repeating: set, count: max(1, setCount)).map {
                ParsedSet(repsMin: $0.repsMin, repsMax: $0.repsMax, weightKg: $0.weightKg, percentOfMax: $0.percentOfMax, rpe: $0.rpe)
            }
        )
    }

    /// Parse a whole day chunk with the line parser.
    public static func parse(chunk: ProgramSegmenter.DayChunk, defaultUnit: WeightUnit) -> ParsedDay {
        let exercises = chunk.body
            .components(separatedBy: .newlines)
            .compactMap { parse(line: $0, defaultUnit: defaultUnit) }
        return ParsedDay(name: chunk.header.isEmpty ? "Day" : chunk.header, exercises: exercises)
    }

    static func parseWeight(_ token: String, defaultUnit: WeightUnit) -> (Double, WeightUnit)? {
        guard let value = Double(numeric(token)) else { return nil }
        let lower = token.lowercased()
        let unit: WeightUnit = lower.contains("lb") || lower.contains("#") ? .pounds
            : lower.contains("kg") ? .kilograms
            : defaultUnit
        return (value, unit)
    }

    static func numeric<S: StringProtocol>(_ s: S) -> String {
        String(s.map { $0 == "," ? "." : $0 }.filter { $0.isNumber || $0 == "." })
    }
}
