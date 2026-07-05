import AppIntents
import FortichePack

/// The app's AppIntents metadata provider. Declaring the package as a
/// dependency pulls in the intents, entities, and AppShortcutsProvider defined
/// in FortichePack (required for SwiftPM-hosted App Intents). Kept as its own
/// non-isolated type — the @main App type is MainActor-isolated and can't carry
/// this conformance.
struct ForticheIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [FortichePackage.self]
    }
}
