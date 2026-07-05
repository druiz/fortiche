import SwiftUI
import SwiftData
import FortichePack

/// Paste/type a program as free text; Apple Intelligence turns it into a
/// structured template, streamed day by day into the review screen.
struct TemplateImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var model: TemplateImportModel

    init(model: TemplateImportModel = TemplateImportModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .editing, .failed:
                    editor
                case .parsing:
                    parsingProgress
                case .review:
                    TemplateReviewView(model: model, onSave: save)
                }
            }
            .navigationTitle(model.isEditingExisting ? "Edit Program" : "New Program")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if model.isEditingExisting, model.phase == .review, !model.sourceText.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit Text", systemImage: "text.quote") { model.editText() }
                    }
                }
            }
        }
    }

    private var editor: some View {
        Form {
            Section("Name") {
                TextField("My Program", text: $model.programName)
            }
            Section {
                TextEditor(text: $model.sourceText)
                    .frame(minHeight: 220)
                    .font(.body.monospaced())
                    .overlay(alignment: .topLeading) {
                        if model.sourceText.isEmpty { placeholder }
                    }
            } header: {
                Text("Program text")
            } footer: {
                availabilityFooter
            }
            if case .failed(let message) = model.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    model.parse()
                } label: {
                    Label("Create Program", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var placeholder: some View {
        Text("""
        Push A:
        Bench Press 3x5 @ 80kg
        OHP 3x8-12 @ 40kg
        Dips 3xAMRAP

        Pull A:
        …
        """)
        .font(.body.monospaced())
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
        .padding(.leading, 4)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var availabilityFooter: some View {
        switch model.availability {
        case .available:
            Text("Parsed on-device with Apple Intelligence. Nothing leaves your \(UIDevice.current.model).")
        case .downloading:
            Text("The on-device model is still downloading — using the basic parser until it's ready.")
        case .unavailable(let reason):
            Text("\(reason) Using the basic parser — works best with 'Exercise 3x8 @ 80kg' style lines.")
        }
    }

    private var parsingProgress: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading your program…")
                        .foregroundStyle(.secondary)
                }
            }
            if !model.parsedDays.isEmpty {
                Section("Found so far") {
                    ForEach(model.parsedDays) { day in
                        HStack {
                            Text(day.name)
                            Spacer()
                            Text("\(day.exercises.count) exercises")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func save() {
        let program = model.finalizedProgram()
        if let uuid = model.editingUUID,
           let existing = try? modelContext.fetch(
               FetchDescriptor<WorkoutTemplate>(predicate: #Predicate { $0.uuid == uuid })
           ).first {
            program.apply(to: existing, sourceText: model.sourceText.isEmpty ? nil : model.sourceText, in: modelContext)
        } else {
            modelContext.insert(program.makeTemplate(sourceText: model.sourceText))
        }
        try? modelContext.save()
        pushTemplatesToWatch(modelContext)
        dismiss()
    }
}

#Preview {
    TemplateImportView()
        .modelContainer(try! ForticheStore.container(.inMemory))
}
