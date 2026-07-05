import Foundation
// FoundationModels is API-unavailable in the watch *simulator* slice (the
// on-watch LLM needs real hardware); real watchOS 27 devices do have it.
#if canImport(FoundationModels) && !(os(watchOS) && targetEnvironment(simulator))
import FoundationModels
#endif

// MARK: - Protocol & availability

public enum ParserAvailability: Sendable, Equatable {
    case available
    /// Transient: the on-device model is still downloading.
    case downloading
    /// Apple Intelligence off or unsupported device — heuristic fallback only.
    case unavailable(reason: String)
}

public protocol ProgramParsing: Sendable {
    /// Parse raw program text. `onDay` streams each parsed day as it completes
    /// (for progressive UI); the returned program contains all days.
    func parse(
        _ text: String,
        suggestedName: String,
        defaultUnit: WeightUnit,
        onDay: @Sendable @escaping (ParsedDay) -> Void
    ) async throws -> ParsedProgram
}

// MARK: - Heuristic parser (always available; also the per-day fallback)

public struct HeuristicProgramParser: ProgramParsing {
    public init() {}

    public func parse(
        _ text: String,
        suggestedName: String,
        defaultUnit: WeightUnit,
        onDay: @Sendable @escaping (ParsedDay) -> Void
    ) async throws -> ParsedProgram {
        let days = ProgramSegmenter.segment(text).map {
            HeuristicLineParser.parse(chunk: $0, defaultUnit: defaultUnit)
        }
        days.forEach(onDay)
        return ParsedProgram(name: suggestedName, days: days, usedFallback: true)
    }
}

// FoundationModels is API-unavailable in the watch *simulator* slice (the
// on-watch LLM needs real hardware); real watchOS 27 devices do have it.
#if canImport(FoundationModels) && !(os(watchOS) && targetEnvironment(simulator))

// MARK: - Guided-generation schema
// One day per generation request: pass 1 (deterministic segmentation) keeps each
// request small; deep nesting and long programs degrade guided generation.

@Generable
struct GeneratedDay {
    @Guide(description: "Short name of this training day, e.g. 'Push A' or 'Day 1'. Use the header from the text when present.")
    var name: String
    @Guide(description: "Every exercise of this day, in the order written.")
    var exercises: [GeneratedExercise]
}

@Generable
struct GeneratedExercise {
    @Guide(description: "Exercise name exactly as written in the program, without set/rep/weight notation.")
    var name: String
    @Guide(description: "Set prescriptions. '3x8 @ 100kg' is ONE group with setCount 3 and reps 8. Use multiple groups only when sets differ from each other, e.g. '5/3/1' is three groups with setCount 1 and reps 5, 3, 1.")
    var setGroups: [GeneratedSetGroup]
    @Guide(description: "Rest between sets in seconds if the text specifies it, else null.")
    var restSeconds: Int?
}

@Generable
struct GeneratedSetGroup {
    @Guide(description: "How many sets share this exact prescription. The 3 in '3x8'.")
    var setCount: Int
    @Guide(description: "Target repetitions per set. For a range like 8-12 use the lower bound. 0 for AMRAP/max reps.")
    var reps: Int
    @Guide(description: "Upper bound of a rep range like 8-12, else same as reps.")
    var repsUpper: Int
    @Guide(description: "Weight value as written, else null for bodyweight or unspecified.")
    var weight: Double?
    @Guide(description: "Unit of the weight value.")
    var unit: GeneratedWeightUnit?
    @Guide(description: "RPE (rate of perceived exertion) if specified, else null.")
    var rpe: Double?
}

@Generable
enum GeneratedWeightUnit {
    case kilograms
    case pounds
    /// Percent of one-rep max, e.g. "65%".
    case percentOfMax
}

// MARK: - Intelligent parser

public struct IntelligentProgramParser: ProgramParsing {
    public init() {}

    public static var availability: ParserAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.modelNotReady):
            return .downloading
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence is turned off in Settings.")
        case .unavailable(let other):
            return .unavailable(reason: "Apple Intelligence is unavailable (\(String(describing: other))).")
        }
    }

    public func parse(
        _ text: String,
        suggestedName: String,
        defaultUnit: WeightUnit,
        onDay: @Sendable @escaping (ParsedDay) -> Void
    ) async throws -> ParsedProgram {
        let chunks = ProgramSegmenter.segment(text)
        var days: [ParsedDay] = []
        var usedFallback = false

        for chunk in chunks {
            // Fresh session per day: bounded context, day-scoped retries.
            do {
                let day = try await parseDay(chunk: chunk, defaultUnit: defaultUnit)
                days.append(day)
                onDay(day)
            } catch {
                // Guardrail refusals, context overflows, malformed generations —
                // degrade to the deterministic parser for this day only.
                let fallbackDay = HeuristicLineParser.parse(chunk: chunk, defaultUnit: defaultUnit)
                usedFallback = true
                days.append(fallbackDay)
                onDay(fallbackDay)
            }
        }
        return ParsedProgram(name: suggestedName, days: days, usedFallback: usedFallback)
    }

    func parseDay(chunk: ProgramSegmenter.DayChunk, defaultUnit: WeightUnit) async throws -> ParsedDay {
        let session = LanguageModelSession(instructions: """
            You convert one day of a strength-training program from raw text into structured data.
            Rules:
            - Keep exercises in the order written; include every exercise line.
            - "AMRAP" or "max reps" means reps = 0.
            - A bare weight number uses the program's unit context; when truly ambiguous assume \(defaultUnit == .pounds ? "pounds" : "kilograms").
            - Percentages like "65%" are percent of one-rep max, not a weight (unit percentOfMax).
            - Do not invent exercises, sets, weights, or rest times that are not in the text.
            """)

        let prompt = """
            Day header: \(chunk.header.isEmpty ? "(none)" : chunk.header)
            Program text for this day:
            \(chunk.body)
            """

        let response = try await session.respond(
            to: prompt,
            generating: GeneratedDay.self,
            options: GenerationOptions(temperature: 0)
        )
        return ParsedDay(generated: response.content, fallbackName: chunk.header)
    }
}

extension ParsedDay {
    init(generated: GeneratedDay, fallbackName: String) {
        let name = generated.name.isEmpty ? (fallbackName.isEmpty ? "Day" : fallbackName) : generated.name
        self.init(
            name: name,
            exercises: generated.exercises.compactMap { exercise in
                guard !exercise.name.isEmpty else { return nil }
                return ParsedExercise(
                    name: exercise.name,
                    // The model sometimes emits 0 for "not specified" — treat as
                    // unset so the sensible default applies downstream.
                    restSeconds: (exercise.restSeconds ?? 0) > 0 ? exercise.restSeconds : nil,
                    sets: exercise.setGroups.flatMap { group -> [ParsedSet] in
                        var weightKg: Double?
                        var percent: Double?
                        switch group.unit {
                        case .kilograms: weightKg = group.weight
                        case .pounds: weightKg = group.weight.map { WeightUnit.pounds.toKilograms($0) }
                        case .percentOfMax: percent = group.weight
                        case nil: weightKg = group.weight
                        }
                        let count = min(30, max(1, group.setCount))
                        return (0..<count).map { _ in
                            ParsedSet(
                                repsMin: max(0, group.reps),
                                repsMax: max(group.reps, group.repsUpper),
                                weightKg: weightKg,
                                percentOfMax: percent,
                                rpe: group.rpe
                            )
                        }
                    }
                )
            }
        )
    }
}
#endif

// MARK: - Canonicalization

extension ParsedProgram {
    /// Best-effort match of each exercise against the bundled library.
    /// Only confident (exact-normalized) matches are auto-assigned; the review
    /// UI lets the user pick from looser candidates. Matching is optional by
    /// design — unmatched exercises stay free-form.
    public func canonicalized(with library: ExerciseLibrary = .shared) -> ParsedProgram {
        var program = self
        for dayIndex in program.days.indices {
            for exerciseIndex in program.days[dayIndex].exercises.indices {
                let name = program.days[dayIndex].exercises[exerciseIndex].name
                if let best = library.match(name: name, limit: 1).first,
                   ExerciseLibrary.normalize(best.name) == ExerciseLibrary.normalize(name) {
                    program.days[dayIndex].exercises[exerciseIndex].librarySlug = best.slug
                }
            }
        }
        return program
    }
}
