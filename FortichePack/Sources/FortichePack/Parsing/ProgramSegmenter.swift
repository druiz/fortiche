import Foundation

/// Deterministic pass 1 of the two-pass parse: split raw program text into
/// per-day chunks so each chunk fits comfortably in the on-device model's
/// context (and failures/retries stay day-scoped).
public enum ProgramSegmenter {
    public struct DayChunk: Sendable, Equatable {
        public var header: String
        public var body: String
    }

    static let weekdays = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
    ]

    /// Lines that look like a day header rather than an exercise prescription.
    static func isDayHeader(_ rawLine: String) -> Bool {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }

        // Markdown-style headers are headers regardless of content.
        if line.hasPrefix("#") { return true }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ ")).lowercased()

        // Set/rep notation ("3x8", "5/3/1", "@ 100kg") marks an exercise line.
        if line.range(of: #"\d+\s*[x×]\s*\d+"#, options: .regularExpression) != nil { return false }
        if line.contains("@") { return false }

        let head = line.trimmingCharacters(in: CharacterSet(charactersIn: ":-–— "))
        if head.range(of: #"^(day|week|jour|semaine)\b"#, options: .regularExpression) != nil { return true }
        if weekdays.contains(where: { head == $0 || head.hasPrefix($0 + " ") || head.hasPrefix($0 + ":") }) { return true }
        // "Push A", "Upper 1", "Legs" style: short, colon-terminated or set off by blank lines
        // is decided by the caller; here only the strong signals count.
        if rawLine.trimmingCharacters(in: .whitespaces).hasSuffix(":") && line.count <= 40 { return true }
        return false
    }

    /// Split into day chunks. Text with no recognizable headers becomes a
    /// single unnamed chunk (the model/fallback still parses its exercises).
    public static func segment(_ text: String) -> [DayChunk] {
        let lines = text.components(separatedBy: .newlines)
        var chunks: [DayChunk] = []
        var currentHeader: String?
        var currentBody: [String] = []

        func flush() {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if currentHeader != nil || !body.isEmpty {
                chunks.append(DayChunk(
                    header: currentHeader?.trimmingCharacters(in: CharacterSet(charactersIn: "#*_:-–— ")) ?? "",
                    body: body
                ))
            }
            currentHeader = nil
            currentBody = []
        }

        for line in lines {
            if isDayHeader(line) {
                flush()
                currentHeader = line
            } else {
                currentBody.append(line)
            }
        }
        flush()

        // Drop bodyless chunks: program titles before the first real day header,
        // trailing headers, and "Rest day" markers — none contain exercises.
        var result = chunks.filter { !$0.body.isEmpty }

        // A headerless leading chunk with no set notation is preamble
        // (program title, description), not a training day.
        if result.count > 1, let first = result.first, first.header.isEmpty,
           first.body.range(of: #"\d+\s*x\s*(\d|amrap)|@"#, options: [.regularExpression, .caseInsensitive]) == nil {
            result.removeFirst()
        }
        return result
    }
}
