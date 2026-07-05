import AppIntents
import FortichePack

/// AppIntents metadata provider for the widget extension.
///
/// The Live Activity's buttons reference intents defined in FortichePack
/// (a SwiftPM package). Every binary that uses package-hosted App Intents
/// must register the package via `AppIntentsPackage`, or the system can
/// fail to resolve the intent at tap time — the button then silently does
/// nothing. The main app has an equivalent registration.
struct ForticheWidgetsIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [FortichePackage.self]
    }
}
