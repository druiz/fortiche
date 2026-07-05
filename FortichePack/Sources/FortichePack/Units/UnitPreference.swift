import Foundation

extension WeightUnit {
    public static let preferenceKey = "weightUnit"

    /// User's display unit, shared by app targets (`@AppStorage(WeightUnit.preferenceKey)`
    /// binds the same store). Defaults from the locale until the user chooses.
    public static var preferred: WeightUnit {
        get {
            UserDefaults.standard.string(forKey: preferenceKey).flatMap(WeightUnit.init(rawValue:))
                ?? .default()
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
        }
    }
}
