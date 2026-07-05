import Foundation
import Testing
@testable import FortichePack

@Suite struct WeightTests {
    @Test func kilogramsToPoundsKnownValues() {
        #expect(abs(WeightUnit.pounds.fromKilograms(100) - 220.462) < 0.001)
        #expect(abs(WeightUnit.pounds.toKilograms(225) - 102.058) < 0.001)
        #expect(WeightUnit.kilograms.fromKilograms(80) == 80)
    }

    @Test(arguments: [0.0, 2.5, 60, 102.5, 142.7, 300])
    func roundTripStaysWithinDisplayPrecision(kg: Double) {
        for unit in WeightUnit.allCases {
            let roundTripped = unit.toKilograms(unit.fromKilograms(kg))
            #expect(abs(roundTripped - kg) < 0.000_001)
        }
    }

    @Test func formattingTrimsZerosAndUsesSymbol() {
        #expect(WeightUnit.kilograms.format(kilograms: 80) == "80 kg")
        #expect(WeightUnit.kilograms.format(kilograms: 82.5) == "82.5 kg")
        #expect(WeightUnit.pounds.format(kilograms: 102.05828) == "225 lb")
    }

    @Test func localeDefaults() {
        #expect(WeightUnit.default(for: Locale(identifier: "en_US")) == .pounds)
        #expect(WeightUnit.default(for: Locale(identifier: "fr_FR")) == .kilograms)
    }
}
