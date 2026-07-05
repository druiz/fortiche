import Foundation
import SwiftData

/// Central ModelContainer construction so every target agrees on schema and
/// sync behavior:
/// - iPhone app: CloudKit-synced (falls back to local-only when iCloud is
///   unavailable, e.g. simulator without an account or missing entitlement).
/// - Watch app: always local-only (`cloudKitDatabase: .none`) — templates
///   arrive over WatchConnectivity, finished logs are shipped back to the phone.
/// - Widgets: read-only view of the app's store via the shared App Group.
public enum ForticheStore {
    public static let schema = Schema([
        WorkoutTemplate.self, TemplateDay.self, TemplateExercise.self, TemplateSet.self,
        WorkoutLog.self, LoggedExercise.self, LoggedSet.self,
    ])

    public static let appGroupID = "group.com.davidruiz.fortiche"

    public enum Mode {
        /// iPhone app store: lives in the App Group (widgets read it), tries CloudKit.
        case phone
        /// Watch app store: local, never CloudKit.
        case watch
        /// Tests/previews.
        case inMemory
    }

    public static func container(_ mode: Mode) throws -> ModelContainer {
        switch mode {
        case .inMemory:
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [config])

        case .watch:
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [config])

        case .phone:
            let url = storeURL()
            do {
                let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .automatic)
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                // No iCloud account / container: keep working locally rather than failing.
                let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: [config])
            }
        }
    }

    /// Store location inside the App Group so the widget extension can read it.
    /// Falls back to the default location if the group is unavailable (e.g.
    /// unsigned local builds).
    static func storeURL() -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? URL.applicationSupportDirectory
        return base.appending(path: "Fortiche.store")
    }
}
