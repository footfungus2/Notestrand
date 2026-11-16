import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.presentationMode) private var presentationMode
    @State private var keys = Dictionary(uniqueKeysWithValues: ProviderID.keyProviders.map { ($0, KeyStore.get($0) ?? "") })
    @State private var savedKeys = Set(ProviderID.keyProviders.filter { KeyStore.get($0) != nil })
    @State private var showingVaultPicker = false
    @State private var vaultError: String?
    @State private var noteCount: Int?
    @State private var pendingCount = 0
    @ObservedObject private var chatgpt = ChatGPTAuth.shared
    @State private var chatgptError: String?
    @AppStorage(Prefs.learnerName) private var learnerName = ""
    @AppStorage(Prefs.learnerPronouns) private var learnerPronouns = ""
    @AppStorage(Prefs.customInstructions) private var customInstructions = ""
    @AppStorage(Prefs.studyLevel) private var studyLevel = ""
    @AppStorage(Prefs.tutorTone) private var tutorTone = ""
    @AppStorage(Prefs.replyLength) private var replyLength = ""
    @AppStorage(Prefs.spelling) private var spelling = ""
    @AppStorage(Prefs.showSpeed) private var showSpeed = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.reynardLinks) private var reynardLinks = false
    @AppStorage(Prefs.checkUpdates) private var checkUpdates = true
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @AppStorage(Prefs.accent) private var accent = "blue"
    @AppStorage(Prefs.textSize) private var textSize = Prefs.defaultTextSize
    @AppStorage(Prefs.webAccess) private var webAccess = true
    @AppStorage(Prefs.searchProvider) private var searchProvider = "free"
    @State private var searchKey = ""
    @State private var searchKeySaved = false
    @State private var searchKeyEdited = false
    @State private var quickPrompts = QuickPrompt.all
    @State private var editingPrompt: QuickPrompt?
    @State private var showingOnboarding = false
    @AppStorage(Prefs.vaultAccess) private var vaultAccess = VaultAccess.readWrite.rawValue
    @State private var confirmingWrite = false

    private var selectedSearchProvider: SearchProvider {
        SearchProvider(rawValue: searchProvider) ?? .free
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API keys")) {
                    ForEach(ProviderID.keyProviders) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(provider.label).font(.headline)
                            HStack {
                                SecureField(savedKeys.contains(provider) ? "Saved" : "Not set", text: keyBinding(for: provider))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onSubmit { saveKey(for: provider) }
                                if savedKeys.contains(provider) {
                                    Button("Remove") {
                                        keys[provider] = ""
                                        saveKey(for: provider)
                                    }
                                }
                            }
                            Text(provider.keyHint).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("ChatGPT plan"),
                        footer: Text("Uses your ChatGPT Plus or Pro allowance instead of an API key. Set how much this app may use in ChatGPT Settings → Usage. If the ChatGPT login page won't load, sign in with the Reynard browser instead.")) {
                    if let c = chatgpt.credentials {
                        Text("Signed in as \(c.email ?? "your ChatGPT account")")
                        Button("Sign out", role: .destructive) { Task { await chatgpt.signOut() } }
                    } else {
                        Button {
                            Task {
                                do { try await chatgpt.signIn(); chatgptError = nil } catch { chatgptError = error.localizedDescription }
                            }
                        } label: {
                            HStack {
                                Text("Continue with ChatGPT")
                                if chatgpt.signingIn { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(chatgpt.signingIn)
                        ReynardSignIn(chatgpt: chatgpt) { chatgptError = $0 }
                    }
                    if let e = chatgptError { Text(e).foregroundColor(.red) }
                }

                Section(header: Text("Obsidian vault"), footer: Text(vaultAccess == VaultAccess.readWrite.rawValue
                    ? VaultAccess.writeWarning
                    : "Notestrand only ever has access to the vault folder you choose, never other files on your iPad. Read only: the AI can't create or change any note.")) {
                    Text(app.vault.name ?? "Not chosen")
                    Picker("Access", selection: Binding(get: { vaultAccess }, set: { new in
                        // Allowing writes asks first; going back to read-only never needs to.
                        if new == VaultAccess.readWrite.rawValue { confirmingWrite = true } else { vaultAccess = new }
                    })) {
                        ForEach(VaultAccess.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text((VaultAccess(rawValue: vaultAccess) ?? .readWrite).summary).font(.footnote).foregroundColor(.secondary)
                    if let count = noteCount {
                        Text("\(count) notes")
                        if pendingCount > 0 {
                            Text("\(pendingCount) still downloading from iCloud")
                        }
                    }
                    Button("Choose vault folder") { showingVaultPicker = true }
                    if let vaultError {
                        Text(vaultError).foregroundColor(.red)
                    }
                }

                Section(header: Text("Memory"), footer: Text("The AI reads this note at the start of every conversation. You can edit or delete anything.")) {
                    NavigationLink("What the AI remembers") {
                        MemoryEditor().environmentObject(app)
                    }
                }

                Section(header: Text("About you"), footer: Text("The tutor uses these when talking to you.")) {
                    TextField("Your name", text: $learnerName)
                    Picker("Pronouns", selection: $learnerPronouns) {
                        Text("Not set").tag("")
                        Text("they/them").tag("they/them")
                        Text("she/her").tag("she/her")
                        Text("he/him").tag("he/him")
                    }
                    .pickerStyle(MenuPickerStyle())
                    TextField("What level you study at, e.g. GCSE, A-level, university", text: $studyLevel)
                }

                Section(header: Text("Tutor style"), footer: Text("Applies to every mode. Custom instructions below can fine-tune it further.")) {
                    Picker("Tone", selection: $tutorTone) {
                        Text("Balanced").tag("")
                        Text("Encouraging").tag("encouraging")
                        Text("Direct").tag("direct")
                    }
                    Picker("Reply length", selection: $replyLength) {
                        Text("Short").tag("short")
                        Text("Normal").tag("")
                        Text("Detailed").tag("detailed")
                    }
                    .pickerStyle(.segmented)
                    Picker("Spelling", selection: $spelling) {
                        Text("Automatic").tag("")
                        Text("British").tag("british")
                        Text("American").tag("american")
                    }
                }

                Section(header: Text("Custom instructions"), footer: Text("Added to every conversation, in every mode.")) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $customInstructions)
                            .frame(minHeight: 110)
                        if customInstructions.isEmpty {
                            Text("e.g. I'm studying A-level Business. Use UK spelling and £.")
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }

                Section(header: Text("Quick prompts"), footer: Text("Type /name in the message box, e.g. /explain photosynthesis.")) {
                    ForEach(quickPrompts) { prompt in
                        Button { editingPrompt = prompt } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("/\(prompt.name)").foregroundColor(.primary)
                                Text(prompt.template).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        quickPrompts.remove(atOffsets: offsets)
                        QuickPrompt.all = quickPrompts
                    }
                    Button("Add prompt") { editingPrompt = QuickPrompt(name: "", template: "") }
                    Button("Reset to defaults", role: .destructive) {
                        quickPrompts = QuickPrompt.defaults
                        QuickPrompt.all = quickPrompts
                    }
                }

                Section(header: Text("Appearance")) {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    HStack {
                        Text("Accent colour")
                        Spacer(minLength: 8)
                        AccentPicker(size: 28)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int(textSize)) pt")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Slider(value: $textSize, in: 14...24, step: 1)
                            Text("Aa").font(.system(size: textSize))
                        }
                    }

                    Toggle("Show reply speed (tokens per second)", isOn: $showSpeed)
                    Toggle("Haptic feedback", isOn: $haptics)
                    Toggle("Open links in Reynard", isOn: $reynardLinks)
                }

                Section(header: Text("Web access"), footer: Text("Without a search key the AI can still open specific web pages. Pages can contain misleading instructions; turn this off for private work.")) {
                    Toggle("Let the AI search and read the web", isOn: $webAccess)
                    if webAccess {
                        Picker("Search with", selection: $searchProvider) {
                            ForEach(SearchProvider.allCases) { provider in
                                Text(provider.label).tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: searchProvider) { _ in
                            searchKey = ""
                            searchKeyEdited = false
                            refreshSearchKeyState()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            if selectedSearchProvider.needsKey {
                            HStack {
                                SecureField(searchKeySaved ? "Saved" : "Not set", text: searchKeyBinding)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onSubmit(saveSearchKey)
                                if searchKeySaved {
                                    Button("Remove") {
                                        searchKey = ""
                                        searchKeyEdited = true
                                        saveSearchKey()
                                    }
                                }
                            }
                            }
                            Text(selectedSearchProvider.keyHint).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("Updates"), footer: Text(Updater.installer == .other
                    ? "Updates download from GitHub. Install them with TrollStore or SideStore."
                    : "Updates download from GitHub and open in \(Updater.installer == .trollStore ? "TrollStore" : "SideStore") to install. Your chats, keys and settings are kept.")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Updater.current).foregroundColor(.secondary)
                    }
                    if let r = updater.available {
                        Button("Install version \(r.version)") { updater.install(r) }
                        Button("What's new") { openLink(r.page) }
                    }
                    Button {
                        Task { await updater.check(manual: true) }
                    } label: {
                        HStack {
                            Text("Check for updates")
                            if updater.checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(updater.checking)
                    if let m = updater.message { Text(m).font(.footnote).foregroundColor(.secondary) }
                    Toggle("Check automatically", isOn: $checkUpdates)
                }

                Section(header: Text("About")) {
                    Button("Welcome and setup") {
                        saveAllKeys()
                        showingOnboarding = true
                    }
                    Text("Prompts and teaching method from LearnHarness (AGPL-3.0).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .alert("Allow writing to your vault?", isPresented: $confirmingWrite) {
            Button("Allow writing") { vaultAccess = VaultAccess.readWrite.rawValue }
            Button("Keep read only", role: .cancel) {}
        } message: {
            Text(VaultAccess.writeWarning)
        }
        .fullScreenCover(isPresented: $showingOnboarding, onDismiss: {
            keys = Dictionary(uniqueKeysWithValues: ProviderID.keyProviders.map { ($0, KeyStore.get($0) ?? "") })
            savedKeys = Set(ProviderID.keyProviders.filter { KeyStore.get($0) != nil })
            refreshVaultNotes()
        }) {
            OnboardingView().environmentObject(app)
        }
        .sheet(isPresented: $showingVaultPicker) {
            VaultFolderPicker(isPresented: $showingVaultPicker, onPick: chooseVault)
        }
        .sheet(item: $editingPrompt) { prompt in
            QuickPromptEditor(prompt: prompt, existing: quickPrompts, onSave: saveQuickPrompt)
        }
        .onAppear {
            refreshVaultNotes()
            refreshSearchKeyState()
        }
        .onDisappear(perform: saveAllKeys)
    }

    private func saveQuickPrompt(_ prompt: QuickPrompt) {
        if let index = quickPrompts.firstIndex(where: { $0.id == prompt.id }) {
            quickPrompts[index] = prompt
        } else {
            quickPrompts.append(prompt)
        }
        QuickPrompt.all = quickPrompts
    }

    private var searchKeyBinding: Binding<String> {
        Binding(get: { searchKey }, set: { searchKey = $0; searchKeyEdited = true })
    }

    private func refreshSearchKeyState() {
        searchKeySaved = KeyStore.getSecret(selectedSearchProvider.secretName) != nil
    }

    private func saveSearchKey() {
        guard searchKeyEdited else { return }
        let provider = selectedSearchProvider
        KeyStore.setSecret(provider.secretName, searchKey)
        searchKeySaved = KeyStore.getSecret(provider.secretName) != nil
        searchKeyEdited = false
    }

    private func saveAllKeys() {
        saveKeys()
        saveSearchKey()
    }

    private func keyBinding(for provider: ProviderID) -> Binding<String> {
        Binding(get: { keys[provider, default: ""] }, set: { keys[provider] = $0 })
    }

    private func saveKeys() {
        ProviderID.keyProviders.forEach { saveKey(for: $0) }
    }

    private func saveKey(for provider: ProviderID) {
        KeyStore.set(provider, keys[provider] ?? "")
        if KeyStore.get(provider) != nil {
            savedKeys.insert(provider)
        } else {
            savedKeys.remove(provider)
        }
    }

    private func chooseVault(_ url: URL) {
        do {
            try app.vault.setFolder(url)
            vaultError = nil
            refreshVaultNotes()
        } catch {
            vaultError = error.localizedDescription
        }
    }

    private func refreshVaultNotes() {
        guard app.vault.name != nil else {
            noteCount = nil
            pendingCount = 0
            return
        }
        do {
            let result = try app.vault.notes()
            noteCount = result.paths.count
            pendingCount = result.pending
            vaultError = nil
        } catch {
            noteCount = nil
            vaultError = error.localizedDescription
        }
    }
}

struct VaultFolderPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: VaultFolderPicker

        init(_ parent: VaultFolderPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) }
            parent.isPresented = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

struct ModelPicker: View {
    var onPick: (ModelRef) -> Void
    var current: ModelRef? = nil

    @Environment(\.presentationMode) private var presentationMode
    @State private var provider: ProviderID
    @State private var models: [CatalogEntry] = []
    @State private var searchText = ""
    @State private var customModelID = ""
    @State private var isLoading = false
    @State private var loadError: String?

    init(onPick: @escaping (ModelRef) -> Void, current: ModelRef? = nil) {
        self.onPick = onPick
        let stored = current ?? UserDefaults.standard.data(forKey: "defaultModel").flatMap {
            try? JSONDecoder().decode(ModelRef.self, from: $0)
        }
        self.current = stored
        _provider = State(initialValue: stored?.provider ?? .anthropic)
    }

    private var filteredModels: [CatalogEntry] {
        searchText.isEmpty ? models : models.filter {
            [$0.ref.id, $0.ref.label, $0.group].contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Provider", selection: $provider) {
                    ForEach(ProviderID.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                .padding(.top, 8)

                List {
                    if isLoading {
                        ProgressView("Loading models…").frame(maxWidth: .infinity)
                    } else if let loadError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loadError).foregroundColor(.red)
                            Button("Retry") { Task { await fetchModels() } }
                        }
                    } else if filteredModels.isEmpty {
                        Text(models.isEmpty ? "No models returned." : "No matching models.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(ModelCatalog.sections(filteredModels), id: \.group) { section in
                            Section(header: Text(section.group)) {
                                ForEach(section.models) { row($0) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchText)

                HStack(spacing: 8) {
                    TextField("Custom model id", text: $customModelID)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(useCustomModel)
                    Button("Use", action: useCustomModel)
                        .disabled(customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Choose model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task(id: provider) { await fetchModels() }
    }

    private func row(_ entry: CatalogEntry) -> some View {
        let model = entry.ref
        let selected = model.same(current)
        return Button { onPick(model) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label).foregroundColor(.primary)
                    if model.name != nil {
                        Text(model.id).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let window = model.contextWindow {
                    Text(ModelCatalog.short(window)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        .accessibilityLabel("\(ModelCatalog.short(window)) token context")
                }
                if selected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func fetchModels() async {
        // Show the cached list straight away; the network only replaces it.
        let cached = ModelCatalog.cached(provider)
        models = cached
        isLoading = cached.isEmpty
        loadError = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let fetched = try await ModelCatalog.fetch(provider)
            guard !Task.isCancelled else { return }
            models = fetched
            ModelCatalog.remember(fetched, for: provider)
        } catch {
            // A stale list beats an error; only complain when there's nothing to show.
            guard !Task.isCancelled, cached.isEmpty else { return }
            loadError = KeyStore.get(provider) == nil && provider != .chatgpt
                ? "\(error.localizedDescription) Add an API key in Settings."
                : error.localizedDescription
        }
    }

    private func useCustomModel() {
        let id = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        onPick(ModelRef(provider: provider, id: id, wire: ModelCatalog.guessWire(provider, id)))
    }
}

private struct MemoryEditor: View {
    @EnvironmentObject var app: AppState
    @State private var text = ""
    @State private var savedText = ""
    @State private var saveError: String?

    var body: some View {
        Form {
            if app.vault.root == nil {
                Text("Connect your Obsidian vault first.")
            } else {
                TextEditor(text: $text)
                    .frame(minHeight: 300)
                    .accessibilityLabel("Memory note")
                Button("Save", action: save)
                    .disabled(text == savedText || Prefs.vaultAccessValue == .readOnly)
                if Prefs.vaultAccessValue == .readOnly {
                    Text("Your vault is read-only. Allow writing in Settings → Obsidian vault to save changes here.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Button("Revert", action: load)
                if let saveError { Text(saveError).foregroundColor(.red) }
            }
        }
        .navigationTitle("What the AI remembers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        text = app.vault.appNote("Memory.md") ?? ""
        savedText = text
        saveError = nil
    }

    private func save() {
        do {
            let url = try app.vault.appURL("Memory.md")
            // appNote reads at most 40,000 bytes; don't overwrite a longer note with that preview.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 40_000 {
                throw VaultError("This note is too large to edit here. Edit it in Obsidian.")
            }
            try app.vault.write("Memory.md", content: text, append: false)
            savedText = text
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct QuickPromptEditor: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var draft: QuickPrompt
    let existing: [QuickPrompt]
    let onSave: (QuickPrompt) -> Void

    init(prompt: QuickPrompt, existing: [QuickPrompt], onSave: @escaping (QuickPrompt) -> Void) {
        var prompt = prompt
        prompt.name = Self.normalizedName(prompt.name)
        _draft = State(initialValue: prompt)
        self.existing = existing
        self.onSave = onSave
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "/" }
    }

    private var nameError: String? {
        if draft.name == "btw" { return "The /btw command is reserved for side questions." }
        if existing.contains(where: { $0.id != draft.id && $0.name.lowercased() == draft.name }) {
            return "A prompt named /\(draft.name) already exists."
        }
        return nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name")) {
                    TextField("Name (without /)", text: Binding(get: { draft.name }, set: { draft.name = Self.normalizedName($0) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let nameError { Text(nameError).foregroundColor(.red) }
                }
                Section(header: Text("Template"), footer: Text("{input} is replaced by what you type after the command")) {
                    TextEditor(text: $draft.template)
                        .frame(minHeight: 200)
                        .accessibilityLabel("Prompt template")
                }
            }
            .navigationTitle("Quick prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(draft.name.isEmpty || draft.template.trimmed.isEmpty || nameError != nil)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// The accent swatches plus the system colour picker for a colour of the learner's own.
struct AccentPicker: View {
    var size: CGFloat = 34
    @AppStorage(Prefs.accent) private var accent = Accent.blue.rawValue
    @AppStorage(Prefs.customAccent) private var customHex = Accent.blue.hex

    var body: some View {
        HStack(spacing: size * 0.3) {
            ForEach(Accent.presets) { option in
                let on = accent == option.rawValue
                Button { withAnimation(Motion.springOrFade) { accent = option.rawValue } } label: {
                    Circle().fill(option.color).frame(width: size, height: size)
                        .overlay(Circle().stroke(Color.primary.opacity(on ? 0.85 : 0), lineWidth: 2.5).padding(-5))
                        .overlay(Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundColor(.white).opacity(on ? 1 : 0))
                        .frame(width: max(size, 44), height: max(size, 44))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            // Picking a colour here selects it as the accent straight away.
            ColorPicker("Custom colour", selection: Binding(
                get: { Color(customHex) },
                set: { customHex = $0.hex; accent = Accent.custom.rawValue }
            ), supportsOpacity: false)
            .labelsHidden()
            .scaleEffect(size / 28) // the system well is about 28pt; match the swatches
            .overlay(Circle().stroke(Color.primary.opacity(accent == Accent.custom.rawValue ? 0.85 : 0), lineWidth: 2.5).padding(-6))
            .frame(width: max(size, 44), height: max(size, 44))
            .accessibilityAddTraits(accent == Accent.custom.rawValue ? .isSelected : [])
        }
    }
}
