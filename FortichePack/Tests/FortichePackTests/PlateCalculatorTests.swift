import Testing
@testable import FortichePack

@Suite struct PlateCalculatorTests {
    @Test func kilogramsExactBreakdown() {
        let calc = PlateCalculator(unit: .kilograms, barWeightKg: 20)
        let result = calc.plates(forTotal: 100) // (100-20)/2 = 40 per side
        #expect(result.perSide == [25, 15])
        #expect(result.isExact)
        #expect(result.achievedTotal == 100)
    }

    @Test func poundsExactBreakdown() {
        let calc = PlateCalculator(unit: .pounds, barWeightKg: 20.4116) // 45 lb bar
        let result = calc.plates(forTotal: 225) // (225-45)/2 = 90 per side
        #expect(result.perSide == [45, 45])
        #expect(result.isExact)
    }

    @Test func belowBarWeightGivesNoPlates() {
        let calc = PlateCalculator(unit: .kilograms, barWeightKg: 20)
        let result = calc.plates(forTotal: 15)
        #expect(result.perSide.isEmpty)
    }

    @Test func nonDivisibleRoundsDownAndFlagsInexact() {
        let calc = PlateCalculator(unit: .kilograms, barWeightKg: 20)
        let result = calc.plates(forTotal: 101) // 40.5 per side → 40 reachable
        #expect(!result.isExact)
        #expect(result.achievedTotal <= 101)
        #expect(result.achievedTotal == 100)
    }
}
