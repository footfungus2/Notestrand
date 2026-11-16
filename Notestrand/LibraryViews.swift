import SwiftUI

struct RenameSessionSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var title: String
    let onSave: (String) -> Void

    init(title: String, onSave: @escaping (String) -> Void) {
        _title = State(initialValue: title)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("Session title", text: $title)
                    .accessibilityLabel("Session title")
                    .onSubmit(save)
            }
            .navigationTitle("Rename session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(title.trimmed.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        guard !title.trimmed.isEmpty else { return }
        onSave(title.trimmed)
        presentationMode.wrappedValue.dismiss()
    }
}

struct ProjectEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.presentationMode) private var presentationMode
    let project: Project?
    let sessionID: UUID?
    @State private var name: String
    @State private var instructions: String

    init(project: Project? = nil, sessionID: UUID? = nil) {
        self.project = project
        self.sessionID = sessionID
        _name = State(initialValue: project?.name ?? "")
        _instructions = State(initialValue: project?.instructions ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name")) {
                    TextField("Project name", text: $name)
                        .accessibilityLabel("Project name")
                }
                Section(header: Text("Instructions"), footer: Text("Added to every conversation in this project.")) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $instructions)
                            .frame(minHeight: 160)
                            .accessibilityLabel("Project instructions")
                        if instructions.isEmpty {
                            Text("e.g. I'm studying A-level Business (AQA). Use UK spelling and £.")
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                if let project {
                    Section {
                        Button("Delete project", role: .destructive) {
                            app.deleteProject(project.id)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .navigationTitle(project == nil ? "New project" : "Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(name.trimmed.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        let name = name.trimmed
        guard !name.isEmpty else { return }
        var updated = project ?? app.createProject(name)
        updated.name = name
        updated.instructions = instructions
        app.updateProject(updated)
        if let sessionID { app.setProject(sessionID, updated.id) }
        presentationMode.wrappedValue.dismiss()
    }
}
