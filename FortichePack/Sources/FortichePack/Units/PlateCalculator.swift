import Foundation

/// Per-side plate breakdown for a barbell. Pure value logic, unit-tested.
public struct PlateCalculator: Sendable {
    /// Available plates on one side, largest first, in the given unit.
    public let plates: [Double]
    public let barWeight: Double
    public let unit: WeightUnit

    /// Standard plate sets. kg: 25/20/15/10/5/2.5/1.25; lb: 45/35/25/10/5/2.5.
    public init(unit: WeightUnit, barWeightKg: Double = 20) {
        self.unit = unit
        switch unit {
        case .kilograms:
            plates = [25, 20, 15, 10, 5, 2.5, 1.25]
            barWeight = unit.fromKilograms(barWeightKg)
        case .pounds:
            plates = [45, 35, 25, 10, 5, 2.5]
            barWeight = unit.fromKilograms(barWeightKg)
        }
    }

    public struct Result: Sendable, Equatable {
        /// Plates for ONE side, largest first.
        public var perSide: [Double]
        /// Weight reachable with these plates (may be < target if not divisible).
        public var achievedTotal: Double
        /// Requested total.
        public var target: Double
        public var isExact: Bool { abs(achievedTotal - target) < 0.001 }
    }

    /// Break a target total (in display unit) into per-side plates.
    public func plates(forTotal target: Double) -> Result {
        guard target > barWeight else {
            return Result(perSide: [], achievedTotal: barWeight, target: target)
        }
        var remainingPerSide = (target - barWeight) / 2
        var perSide: [Double] = []
        for plate in plates {
            while remainingPerSide >= plate - 0.0001 {
                perSide.append(plate)
                remainingPerSide -= plate
            }
        }
        let achieved = barWeight + 2 * perSide.reduce(0, +)
        return Result(perSide: perSide, achievedTotal: achieved, target: target)
    }

    /// Convenience: work in kilograms end-to-end.
    public func plates(forTotalKg targetKg: Double) -> Result {
        plates(forTotal: unit.fromKilograms(targetKg))
    }
}
