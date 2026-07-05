import Foundation
import SwiftData
import FortichePack

/// What `LiveWorkoutView` needs from a workout host — satisfied by both
/// `PhoneWorkoutController` (phone-authoritative) and `MirroringReceiver`
/// (peer of a watch-authoritative session).
@MainActor
protocol WorkoutHosting: AnyObject {
    var engine: ActiveWorkoutEngine? { get }
    func end(in modelContext: ModelContext) async
}

extension PhoneWorkoutController: WorkoutHosting {}

extension MirroringReceiver: WorkoutHosting {
    /// Ending from the phone: submit `.end` — the envelope is forwarded to the
    /// watch (authority), which finishes HealthKit and echoes the final
    /// snapshot; ingestion/teardown happen on that echo.
    func end(in modelContext: ModelContext) async {
        engine?.submit(.end)
    }
}
