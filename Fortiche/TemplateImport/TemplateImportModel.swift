import Foundation
import Observation
import FortichePack

/// Orchestrates the paste → parse → review → save flow.
@Observable @MainActor
final class TemplateImportModel {
    enum Phase: Equatable {
        case editing
        case parsing(daysDone: Int)
        case review
        case failed(String)
    }

    var sourceText = ""
    var programName = ""
    var phase: Phase = .editing
    /// Days stream in as the parser finishes each one.
    private(set) var parsedDays: [ParsedDay] = []
    private(set) var program: ParsedProgram?
    private(set) var usedFallback = false

    let availability = IntelligentProgramParser.availability

    func parse() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parsedDays = []
        phase = .parsing(daysDone: 0)
        let text = sourceText
        let name = programName.isEmpty ? "My Program" : programName
        let unit = WeightUnit.preferred

        let parser: any ProgramParsing = availability == .available
            ? IntelligentProgramParser()
            : HeuristicProgramParser()

        Task {
            do {
                let parsed = try await parser.parse(text, suggestedName: name, defaultUnit: unit) { day in
                    Task { @MainActor in
                        self.parsedDays.append(day)
                        self.phase = .parsing(daysDone: self.parsedDays.count)
                    }
                }
                let canonicalized = parsed.canonicalized()
                self.program = canonicalized
                self.parsedDays = canonicalized.days
                self.usedFallback = canonicalized.usedFallback
                self.phase = canonicalized.days.isEmpty
                    ? .failed("No training days found in that text. Check the format and try again.")
                    : .review
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Review edits (operate on parsedDays; program is rebuilt on save)

    func updateDayName(_ dayID: UUID, to name: String) {
        guard let index = parsedDays.firstIndex(where: { $0.id == dayID }) else { return }
        parsedDays[index].name = name
    }

    func updateExercise(_ exercise: ParsedExercise, inDay dayID: UUID) {
        guard let dayIndex = parsedDays.firstIndex(where: { $0.id == dayID }),
              let exerciseIndex = parsedDays[dayIndex].exercises.firstIndex(where: { $0.id == exercise.id })
        else { return }
        parsedDays[dayIndex].exercises[exerciseIndex] = exercise
    }

    func deleteExercise(_ exerciseID: UUID, inDay dayID: UUID) {
        guard let dayIndex = parsedDays.firstIndex(where: { $0.id == dayID }) else { return }
        parsedDays[dayIndex].exercises.removeAll { $0.id == exerciseID }
    }

    func finalizedProgram() -> ParsedProgram {
        ParsedProgram(
            name: programName.isEmpty ? "My Program" : programName,
            days: parsedDays.filter { !$0.exercises.isEmpty },
            usedFallback: usedFallback
        )
    }
}
