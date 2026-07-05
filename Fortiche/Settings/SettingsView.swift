import SwiftUI
import FortichePack

/// Settings tab: weight-unit choice, gym tools, and acknowledgements.
/// The unit picker writes through `@AppStorage` to the same defaults key
/// `WeightUnit.preferred` reads, so every screen picks the change up live.
struct SettingsView: View {
    @AppStorage(WeightUnit.preferenceKey) private var unitRaw = WeightUnit.default().rawValue

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .kilograms }

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Weight", selection: $unitRaw) {
                        Text("Kilograms (kg)").tag(WeightUnit.kilograms.rawValue)
                        Text("Pounds (lb)").tag(WeightUnit.pounds.rawValue)
                    }
                }

                Section("Tools") {
                    NavigationLink {
                        PlateCalculatorView(unit: unit)
                    } label: {
                        Label("Plate Calculator", systemImage: "dumbbell")
                    }
                }

                Section {
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                } footer: {
                    Text("Fortiche · iOS 27 strength training")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// "What plates do I put on the bar?" — target weight in, per-side plate
/// breakdown out. State stays in canonical kilograms; only the steppers and
/// labels speak the display unit.
struct PlateCalculatorView: View {
    let unit: WeightUnit
    @State private var targetKg: Double
    @State private var barKg: Double = 20

    init(unit: WeightUnit) {
        self.unit = unit
        _targetKg = State(initialValue: 60)
    }

    private var calculator: PlateCalculator {
        PlateCalculator(unit: unit, barWeightKg: barKg)
    }

    private var result: PlateCalculator.Result {
        calculator.plates(forTotalKg: targetKg)
    }

    var body: some View {
        Form {
            Section("Target") {
                // Step in whole display-unit increments (2.5 lb / 2.5 kg feel)
                // even though the bound value is kilograms.
                Stepper(value: $targetKg, in: barKg...500, step: unit.toKilograms(unit.displayStep)) {
                    Text(unit.format(kilograms: targetKg)).font(.headline)
                }
                Picker("Bar", selection: $barKg) {
                    Text(unit.format(kilograms: 20)).tag(20.0)
                    Text(unit.format(kilograms: 15)).tag(15.0)
                    Text(unit.format(kilograms: 10)).tag(10.0)
                }
            }

            Section("Per side") {
                if result.perSide.isEmpty {
                    Text("Just the bar").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ForEach(Array(result.perSide.enumerated()), id: \.offset) { _, plate in
                            Text(unit.format(kilograms: unit.toKilograms(plate)).replacingOccurrences(of: " \(unit.symbol)", with: ""))
                                .font(.headline.monospacedDigit())
                                .frame(minWidth: 40, minHeight: 40)
                                .background(Circle().fill(.tint.opacity(0.2)))
                        }
                    }
                }
                if !result.isExact {
                    Label(
                        "Closest reachable: \(unit.format(kilograms: unit.toKilograms(result.achievedTotal)))",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Plate Calculator")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Credits for bundled third-party data (the free-exercise-db dataset).
struct LicensesView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("free-exercise-db").font(.headline)
                    Text("Exercise dataset (~870 exercises). Public domain (Unlicense), originally derived from exercises.json by Ollie Jennings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("github.com/yuhonas/free-exercise-db",
                         destination: URL(string: "https://github.com/yuhonas/free-exercise-db")!)
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Data")
            } footer: {
                Text("Exercise names, categories, and instructions are used under the Unlicense (public domain dedication).")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
