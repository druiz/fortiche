import SwiftUI
import SwiftData
import FortichePack

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var workoutController = PhoneWorkoutController.shared
    @State private var mirror = MirroringReceiver.shared

    var body: some View {
        TabView {
            Tab("Programs", systemImage: "list.bullet.rectangle") {
                TemplateListView()
            }
            Tab("History", systemImage: "clock") {
                HistoryView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { workoutController.isActive || mirror.isActive },
            set: { if !$0 { /* dismissal handled by End flow */ } }
        )) {
            LiveWorkoutView(controller: workoutController.isActive ? workoutController : mirror)
        }
        .task {
            workoutController.recoverIfNeeded()
            if !ProcessInfo.processInfo.arguments.contains("--skip-health") {
                await mirror.requestAuthorization()
            }
            pushTemplatesToWatch(modelContext)
        }
    }
}

struct TemplateListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutTemplate.createdAt, order: .reverse) private var templates: [WorkoutTemplate]
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]
    @State private var showingImport = false
    /// Expansion is user-toggleable; nil = "not decided yet" (defaults open
    /// for the active program, collapsed for the rest).
    @State private var expanded: [UUID: Bool] = [:]

    private var activeTemplateUUID: UUID? {
        ProgramSchedule.activeTemplate(in: templates, logs: logs)?.uuid
    }

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    ContentUnavailableView {
                        Label("No programs yet", systemImage: "square.and.pencil")
                    } description: {
                        Text("Paste a workout program as text and Fortiche will turn it into a structured plan.")
                    } actions: {
                        Button("New Program") { showingImport = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    programList
                }
            }
            .navigationTitle("Programs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Program", systemImage: "plus") { showingImport = true }
                }
            }
            .sheet(isPresented: $showingImport) {
                TemplateImportView()
            }
            .task { await runDemoImportIfRequested() }
        }
    }

    private var programList: some View {
        List {
            ForEach(templates) { template in
                let isActive = template.uuid == activeTemplateUUID
                let nextDay = ProgramSchedule.nextDay(in: template, logs: logs)
                Section {
                    DisclosureGroup(isExpanded: expansionBinding(for: template, defaultOpen: isActive)) {
                        ForEach(template.orderedDays) { day in
                            DayRow(
                                day: day,
                                isNextUp: isActive && day.uuid == nextDay?.uuid
                            )
                        }
                        NavigationLink {
                            TemplateDetailView(template: template)
                        } label: {
                            Label("Program details", systemImage: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading) {
                                Text(template.name).font(.headline)
                                Text("^[\(template.orderedDays.count) day](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if isActive, let nextDay {
                                Spacer()
                                Text("Next: \(nextDay.name)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.tint.opacity(0.15)))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .onDelete { offsets in
                for offset in offsets { modelContext.delete(templates[offset]) }
                try? modelContext.save()
                pushTemplatesToWatch(modelContext)
            }
        }
    }

    private func expansionBinding(for template: WorkoutTemplate, defaultOpen: Bool) -> Binding<Bool> {
        Binding(
            get: { expanded[template.uuid] ?? defaultOpen },
            set: { expanded[template.uuid] = $0 }
        )
    }

    /// CLI automation hook: `simctl launch … --demo-import` seeds a sample
    /// program through the real parse → canonicalize → save pipeline.
    private func runDemoImportIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--demo-import"), templates.isEmpty else { return }
        let sample = """
        Push A:
        Bench Press 3x5 @ 80kg
        Overhead Press 3x8-12 @ 40kg
        Dips 3xAMRAP

        Pull A:
        Deadlift 5x3 @ 140kg rest 180s
        Barbell Row 4x8 @ 60kg
        Pullups 3xAMRAP

        Legs:
        Squat 3x5 @ 100kg
        Romanian Deadlift 3x10 @ 80kg
        Leg Press 3x12
        """
        let parser: any ProgramParsing = IntelligentProgramParser.availability == .available
            ? IntelligentProgramParser()
            : HeuristicProgramParser()
        guard let program = try? await parser.parse(
            sample, suggestedName: "Demo PPL", defaultUnit: .kilograms, onDay: { _ in }
        ) else { return }
        let template = program.canonicalized().makeTemplate(sourceText: sample)
        modelContext.insert(template)
        try? modelContext.save()
        pushTemplatesToWatch(modelContext)

        // `--demo-workout` additionally starts the first day (headless UI check).
        if ProcessInfo.processInfo.arguments.contains("--demo-workout"),
           let firstDay = template.orderedDays.first {
            await PhoneWorkoutController.shared.start(day: firstDay)
        }
    }
}

/// One training day inside a collapsible program: start button + next-up badge.
struct DayRow: View {
    let day: TemplateDay
    let isNextUp: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(day.name).font(isNextUp ? .body.bold() : .body)
                    if isNextUp {
                        Text("NEXT UP")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint))
                            .foregroundStyle(.white)
                    }
                }
                Text("^[\(day.orderedExercises.count) exercise](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await PhoneWorkoutController.shared.start(day: day) }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isNextUp ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .disabled(PhoneWorkoutController.shared.isActive)
        }
        .listRowBackground(isNextUp ? Color.accentColor.opacity(0.08) : nil)
    }
}

struct TemplateDetailView: View {
    let template: WorkoutTemplate
    @State private var editing = false
    private let unit = WeightUnit.preferred

    var body: some View {
        List {
            ForEach(template.orderedDays) { day in
                Section(day.name) {
                    ForEach(day.orderedExercises) { exercise in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                            Text(summary(for: exercise))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await PhoneWorkoutController.shared.start(day: day) }
                    } label: {
                        Label("Start \(day.name)", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(PhoneWorkoutController.shared.isActive)
                }
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            TemplateImportView(model: TemplateImportModel(editing: template))
        }
    }

    private func summary(for exercise: TemplateExercise) -> String {
        let sets = exercise.orderedSets
        guard let first = sets.first else { return "No sets" }
        var reps = first.repsMin == 0 ? "AMRAP" : "\(first.repsMin)"
        if first.repsMax > first.repsMin { reps = "\(first.repsMin)–\(first.repsMax)" }
        var text = "\(sets.count)×\(reps)"
        if let percent = first.percentOfMax, percent > 0 {
            text += " @ \(Int(percent))%"
        } else if let kg = first.weightKg, kg > 0 {
            text += " @ \(unit.format(kilograms: kg))"
        }
        text += " · rest \(exercise.restSeconds)s"
        return text
    }
}

#Preview {
    RootView()
        .modelContainer(try! ForticheStore.container(.inMemory))
}
