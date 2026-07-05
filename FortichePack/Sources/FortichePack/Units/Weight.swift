import Foundation

/// User-facing unit system. Weights are always *stored* in kilograms;
/// conversion happens at display/input boundaries only.
public enum WeightUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case kilograms
    case pounds

    public var id: String { rawValue }

    public static let poundsPerKilogram = 2.204_622_621_848_776

    public var symbol: String {
        switch self {
        case .kilograms: "kg"
        case .pounds: "lb"
        }
    }

    /// Sensible default from the user's locale (US/Liberia/Myanmar → pounds).
    public static func `default`(for locale: Locale = .current) -> WeightUnit {
        locale.measurementSystem == .us ? .pounds : .kilograms
    }

    /// Smallest increment users typically adjust by in this unit
    /// (drives crown/stepper granularity).
    public var displayStep: Double {
        switch self {
        case .kilograms: 2.5
        case .pounds: 5
        }
    }

    public func fromKilograms(_ kg: Double) -> Double {
        switch self {
        case .kilograms: kg
        case .pounds: kg * Self.poundsPerKilogram
        }
    }

    public func toKilograms(_ value: Double) -> Double {
        switch self {
        case .kilograms: value
        case .pounds: value / Self.poundsPerKilogram
        }
    }

    /// Round a raw converted value to something displayable/settable on a bar
    /// in this unit (nearest 0.25 kg / 0.5 lb — fine enough for microplates).
    public func roundedForDisplay(_ value: Double) -> Double {
        switch self {
        case .kilograms: (value * 4).rounded() / 4
        case .pounds: (value * 2).rounded() / 2
        }
    }

    /// "80 kg" / "175.5 lb" — trims trailing zeros.
    public func format(kilograms: Double) -> String {
        let value = roundedForDisplay(fromKilograms(kilograms))
        let text = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(text) \(symbol)"
    }
}
