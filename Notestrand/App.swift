import SwiftUI

@main
struct NotestrandApp: App {
    @StateObject private var app = AppState()

    init() {
        // iOS 15's TextEditor has no background modifier; clear it so the composer's placeholder shows.
        UITextView.appearance().backgroundColor = .clear
        _ = TranscriptHost.shared // start loading the transcript page now
    }

    @AppStorage(Prefs.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(Prefs.accent) private var accent = Accent.blue.rawValue
    @AppStorage(Prefs.customAccent) private var customAccent = Accent.blue.hex // repaints when the custom colour changes

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LaunchGate { RootView() }
                .environmentObject(app)
                // The share extension opens notestrand://shared after dropping photos or links in the inbox.
                .onOpenURL { if $0.scheme == ShareInbox.scheme { app.receiveShared() } }
                .preferredColorScheme((Appearance(rawValue: appearance) ?? .system).colorScheme)
                .tint((Accent(rawValue: accent) ?? .blue).color)
                // Color.accentColor (used for fills) reads this, not the tint; set both so a chosen accent applies everywhere.
                .accentColor((Accent(rawValue: accent) ?? .blue).color)
        }
        // Saves run in the background; finish them before iOS may suspend or close the app.
        .onChange(of: scenePhase) {
            if $0 == .background { SessionStore.flush() }
            // Also catches shares that couldn't open the app themselves.
            if $0 == .active { app.receiveShared() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @AppStorage(Prefs.onboarded) private var onboarded = false
    @State private var showSettings = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pickingFor: SessionKind?
    @State private var searchText = ""
    @State private var renamingSession: Session?
    @State private var projectEditor: ProjectEditorRequest?

    private struct ProjectEditorRequest: Identifiable {
        let id = UUID()
        var project: Project?
        var sessionID: UUID?
    }

    private var filteredSessions: [Session] {
        let query = searchText.trimmed
        return app.sessions.filter { session in
            query.isEmpty || session.title.localizedCaseInsensitiveContains(query) ||
                session.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        let sessions = filteredSessions
        let pinned = sessions.filter { $0.pinned == true }
        let ungrouped = sessions.filter { $0.pinned != true && $0.projectId == nil }
        NavigationView {
            // Selection lives on the NavigationLinks only: a List selection binding swallows the tap in compact width.
            List {
                if !pinned.isEmpty {
                    Section(header: Text("Pinned")) { sessionRows(pinned) }
                }
                ForEach(app.projects) { project in
                    let grouped = sessions.filter { $0.pinned != true && $0.projectId == project.id }
                    if !grouped.isEmpty {
                        Section(header: projectHeader(project)) { sessionRows(grouped) }
                    }
                }
                if !ungrouped.isEmpty {
                    Section(header: Text("Sessions")) { sessionRows(ungrouped) }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText)
            .navigationTitle("Notestrand")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                    Button { app.selected = nil } label: { Image(systemName: "house") }
                        .accessibilityLabel("Home")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(SessionKind.allCases) { k in
                            Button { start(k) } label: { Label(k.label, systemImage: icon(k)) }
                        }
                        Divider()
                        Button { projectEditor = ProjectEditorRequest() } label: {
                            Label("New project...", systemImage: "folder.badge.plus")
                        }
                    } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New session")
                }
            }
            detail
        }
        .navigationViewStyle(.columns)
        // Waits for the splash to finish, so the welcome slides up over the app rather than the splash.
        .fullScreenCover(isPresented: Binding(get: { !onboarded && app.launched }, set: { if !$0 { onboarded = true } })) {
            OnboardingView().environmentObject(app)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(app) }
        .sheet(item: $pickingFor) { kind in
            ModelPicker { m in
                app.defaultModel = m
                app.newSession(kind, model: m)
                pickingFor = nil
            }
        }
        .sheet(item: $renamingSession) { session in
            RenameSessionSheet(title: session.title) { app.rename(session.id, $0) }
        }
        .sheet(item: $projectEditor) { request in
            ProjectEditorSheet(project: request.project, sessionID: request.sessionID)
                .environmentObject(app)
        }
    }

    /// Two columns: the right side shows the selected chat, or Home when none is. Driving it from state (not
    /// NavigationLink pushes) is what makes Home, new sessions and shares open reliably even when the sidebar,
    /// and so the chat's row, is hidden or scrolled away. Narrow windows keep the push navigation.
    @ViewBuilder private var detail: some View {
        if sizeClass != .compact, let id = app.selected, app.sessions.contains(where: { $0.id == id }) {
            ChatView(sessionId: id).id(id) // a fresh composer per chat
        } else {
            home
        }
    }

    private var home: some View {
        HomeView(start: start, openSettings: { showSettings = true })
    }

    private func rowLabel(_ s: Session) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).lineLimit(1).foregroundColor(.primary)
                Text("\(s.kind.label) · \(s.model.label)").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: icon(s.kind))
        }
    }

    private func sessionRows(_ sessions: [Session]) -> some View {
        ForEach(sessions) { s in
            Group {
                if sizeClass == .compact {
                    NavigationLink(tag: s.id, selection: $app.selected) { ChatView(sessionId: s.id) } label: { rowLabel(s) }
                } else {
                    Button { app.selected = s.id } label: { rowLabel(s) }
                        .listRowBackground(app.selected == s.id ? Color.accentColor.opacity(0.18) : nil)
                        .accessibilityAddTraits(app.selected == s.id ? .isSelected : [])
                }
            }
            .contextMenu {
                Button { app.togglePin(s.id) } label: {
                    Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin")
                }
                Button { renamingSession = s } label: { Label("Rename...", systemImage: "pencil") }
                Menu {
                    ForEach(app.projects) { project in
                        Button(project.name) { app.setProject(s.id, project.id) }
                    }
                    Button("None") { app.setProject(s.id, nil) }
                    Divider()
                    Button("New project...") { projectEditor = ProjectEditorRequest(sessionID: s.id) }
                } label: { Label("Move to project", systemImage: "folder") }
                Button(role: .destructive) { app.delete(s) } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .onDelete { indices in indices.map { sessions[$0] }.forEach(app.delete) }
    }

    private func projectHeader(_ project: Project) -> some View {
        HStack {
            Text(project.name)
            Spacer()
            Menu {
                Button { projectEditor = ProjectEditorRequest(project: project) } label: {
                    Label("Edit project", systemImage: "pencil")
                }
                Button(role: .destructive) { app.deleteProject(project.id) } label: {
                    Label("Delete project", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Manage project \(project.name)")
        }
        .textCase(nil)
    }

    func start(_ k: SessionKind) {
        if let m = app.defaultModel { app.newSession(k, model: m) } else { pickingFor = k }
    }

    func icon(_ k: SessionKind) -> String {
        switch k {
        case .chat: return "bubble.left.and.bubble.right"
        case .teach: return "graduationcap"
        case .practice: return "pencil.and.outline"
        case .exam: return "checkmark.seal"
        }
    }
}
