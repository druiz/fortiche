#if canImport(AppIntents) && !os(watchOS)
import AppIntents
import Foundation
import SwiftData

/// A training day the user can start by name via Siri / Spotlight.
/// Indexed so it participates in the semantic index behind Personal Context
/// ("what's my next leg day?").
public struct WorkoutDayEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workout Day")

    public var id: UUID
    @Property(title: "Day")
    public var name: String
    @Property(title: "Program")
    public var programName: String

    public init(id: UUID, name: String, programName: String) {
        self.id = id
        self.name = name
        self.programName = programName
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(programName)",
            image: .init(systemName: "figure.strengthtraining.traditional")
        )
    }

    public static let defaultQuery = WorkoutDayQuery()
}

/// Resolves day entities from the phone store. The catalog is small (a
/// handful of programs), so every lookup just flattens all templates.
public struct WorkoutDayQuery: EntityQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [UUID]) async throws -> [WorkoutDayEntity] {
        try Self.allDays().filter { identifiers.contains($0.id) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [WorkoutDayEntity] {
        try Self.allDays()
    }

    @MainActor
    static func allDays() throws -> [WorkoutDayEntity] {
        let container = try ForticheStore.container(.phone)
        let context = container.mainContext
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        return templates.flatMap { template in
            template.orderedDays.map { day in
                WorkoutDayEntity(id: day.uuid, name: day.name, programName: template.name)
            }
        }
    }
}

/// Full enumeration lets Shortcuts offer a browsable day picker (and Siri
/// disambiguate) without a search term.
extension WorkoutDayQuery: EnumerableEntityQuery {
    @MainActor
    public func allEntities() async throws -> [WorkoutDayEntity] {
        try Self.allDays()
    }
}
#endif
