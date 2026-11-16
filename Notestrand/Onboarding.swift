import SwiftUI

/// The N from the app icon as one stroke, in a 24×24 design space (the same path as the thinking indicator).
struct NStrand: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.midX + (x - 12) * s, y: rect.midY + (y - 12) * s) }
        var path = Path()
        path.move(to: p(6, 19))
        path.addLine(to: p(6, 8.5))
        path.addQuadCurve(to: p(9.4, 6.3), control: p(6, 4.6))
        path.addLine(to: p(15.6, 17.2))
        path.addQuadCurve(to: p(18, 16.5), control: p(18, 20.4))
        path.addLine(to: p(18, 5))
        return path
    }
}

/// One way to connect an AI, as a tile on the Connect page, in that service's own logo and colour.
private struct AIOption: Identifiable {
    let provider: ProviderID
    let name: String
    /// Asset name of the service's logo (LobeHub Icons, MIT).
    let logo: String
    /// Brand colour for the logo chip and selection; nil means the logo is plain black/white (OpenAI, OpenCode…).
    let brand: Color?
    let badge: String?
    let keyURL: URL?
    var id: ProviderID { provider }

    static let all = [
        AIOption(provider: .chatgpt, name: "ChatGPT plan", logo: "Logo-openai", brand: Color("#10A37F"), badge: "Plus or Pro", keyURL: nil),
        AIOption(provider: .gemini, name: "Gemini", logo: "Logo-gemini", brand: Color("#3186FF"), badge: "Free tier", keyURL: URL(string: "https://aistudio.google.com/apikey")),
        AIOption(provider: .openrouter, name: "OpenRouter", logo: "Logo-openrouter", brand: Color("#6467F2"), badge: "Free models", keyURL: URL(string: "https://openrouter.ai/keys")),
        AIOption(provider: .anthropic, name: "Claude", logo: "Logo-claude", brand: Color("#D97757"), badge: nil, keyURL: URL(string: "https://console.anthropic.com/settings/keys")),
        AIOption(provider: .openai, name: "OpenAI", logo: "Logo-openai", brand: nil, badge: nil, keyURL: URL(string: "https://platform.openai.com/api-keys")),
        AIOption(provider: .opencode, name: "OpenCode Zen", logo: "Logo-opencode", brand: nil, badge: nil, keyURL: URL(string: "https://opencode.ai/zen")),
    ]
}

/// First-run welcome: what the app does (with live demos), then connecting an AI, a vault, and a few preferences.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var chatgpt = ChatGPTAuth.shared
    @AppStorage(Prefs.onboarded) private var onboarded = false
    @AppStorage(Prefs.learnerName) private var name = ""
    @AppStorage(Prefs.accent) private var accent = Accent.blue.rawValue
    @AppStorage(Prefs.customAccent) private var customAccent = Accent.blue.hex // repaints when the custom colour changes
    @AppStorage(Prefs.customInstructions) private var customInstructions = ""
    @AppStorage(Prefs.vaultAccess) private var vaultAccess = VaultAccess.readWrite.rawValue

    @State private var page: Int
    @State private var finishing = false
    @FocusState private var focused: Bool

    @State private var mode = DemoMode.teach
    @State private var modeTouched = false

    @State private var choice: ProviderID?
    @State private var key = ""
    @State private var keyError: String?
    @State private var checking = false
    @State private var shakes: CGFloat = 0
    @State private var saved = Set(ProviderID.keyProviders.filter { KeyStore.get($0) != nil })
    @State private var signInError: String?

    @State private var pickingVault = false
    @State private var vaultName: String?
    @State private var vaultError: String?
    @State private var studying = ""

    private let last = 4

    init(startPage: Int = 0) { _page = State(initialValue: startPage) }

    private var hasAI: Bool { chatgpt.credentials != nil || !saved.isEmpty }
    private var accentColor: Color { (Accent(rawValue: accent) ?? .blue).color }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            StrandsBackground(page: page, active: !finishing).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    welcome.tag(0)
                    modes.tag(1)
                    connect.tag(2)
                    notes.tag(3)
                    personal.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Under Reduce Motion, button-driven page changes cross-fade instead of sliding.
                .transaction { if reduceMotion { $0.animation = .easeOut(duration: 0.2) } }
                footer
            }
        }
        // The accent picker recolours the whole welcome live (fills read accentColor, controls read tint).
        .tint(accentColor)
        .accentColor(accentColor)
        .animation(Motion.springOrFade, value: page)
        .onChange(of: page) { _ in
            focused = false // or the keyboard stays up for a field that has slid away
            Haptics.select()
        }
        .sheet(isPresented: $pickingVault) { VaultFolderPicker(isPresented: $pickingVault, onPick: connectVault) }
        .onAppear { vaultName = app.vault.name }
        .task(id: page) { await cycleModes() }
    }

    // MARK: chrome

    private var header: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0...last, id: \.self) { i in
                    Capsule().fill(i == page ? Color.accentColor : Color(.systemGray4))
                        .frame(width: i == page ? 22 : 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(page + 1) of \(last + 1)")
            HStack {
                Button { page = max(page - 1, 0) } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .opacity(page > 0 ? 1 : 0)
                .disabled(page == 0 || finishing)
                .accessibilityHidden(page == 0)
                .accessibilityLabel("Back")
                Spacer()
                Button("Skip") { finish(celebrate: false) }
                    .frame(minWidth: 44, minHeight: 44)
                    .opacity(page < last ? 1 : 0)
                    .disabled(page == last || finishing)
                    .accessibilityHidden(page == last)
                    .accessibilityLabel("Skip setup")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var footer: some View {
        Button(action: primary) {
            ZStack {
                if finishing {
                    Image(systemName: "checkmark").font(.title3.weight(.bold)).transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 8) {
                        if checking { ProgressView().tint(.white) }
                        Text(primaryTitle).font(.headline)
                    }
                    .id(primaryTitle)
                    .transition(.opacity)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: 520, minHeight: 52)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(checking || finishing)
        .accessibilityLabel(finishing ? "Done" : primaryTitle)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var primaryTitle: String {
        switch page {
        case 0: return "Get started"
        case 2: return checking ? "Checking key…" : hasAI || !key.trimmed.isEmpty ? "Continue" : "Skip for now"
        case 3: return vaultName == nil ? "Skip for now" : "Continue"
        case last: return "Start learning"
        default: return "Continue"
        }
    }

    private func primary() {
        if page == 2, choice.map({ $0 != .chatgpt }) == true, !key.trimmed.isEmpty { return connectKey(thenAdvance: true) }
        if page == last { return finish(celebrate: true) }
        page += 1
    }

    /// Steps through the three demos on the Modes page until the learner picks one themselves.
    private func cycleModes() async {
        guard page == 1, !reduceMotion else { return }
        while !Task.isCancelled && !modeTouched {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, !modeTouched else { return }
            withAnimation(Motion.springOrFade) { mode = DemoMode(rawValue: (mode.rawValue + 1) % 3)! }
        }
    }

    // MARK: pages

    private var welcome: some View {
        OnboardingPage { shift, _ in
            VStack(spacing: 26) {
                WelcomeMark(active: page == 0)
                    .parallax(shift)
                VStack(spacing: 12) {
                    Text("Welcome to Notestrand")
                        .font(.system(size: 38, weight: .bold))
                        .multilineTextAlignment(.center)
                        .entrance(3)
                    Text("A tutor that finds out what you already know, teaches the rest, and keeps it in your notes.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .entrance(5)
                }
                HStack(spacing: 8) {
                    ForEach(["Teach", "Practice", "Chat"], id: \.self) { tag in
                        Text(tag).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundColor(.accentColor)
                    }
                }
                .entrance(7)
                .accessibilityHidden(true)
            }
        }
    }

    private var modes: some View {
        OnboardingPage { shift, _ in
            VStack(alignment: .leading, spacing: 18) {
                Text("Three ways to learn").font(.largeTitle.weight(.bold))
                HStack(spacing: 8) {
                    ForEach(DemoMode.allCases) { m in
                        Button {
                            modeTouched = true
                            withAnimation(Motion.springOrFade) { mode = m }
                        } label: {
                            Label(m.title, systemImage: m.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(minHeight: 40)
                                .foregroundColor(mode == m ? .white : .primary)
                                .background(Capsule().fill(mode == m ? Color.accentColor : Color(.secondarySystemBackground)))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityAddTraits(mode == m ? .isSelected : [])
                    }
                }
                ZStack {
                    ForEach(DemoMode.allCases) { m in
                        if m == mode {
                            ModeDemo(mode: m, active: page == 1)
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                    removal: .opacity.combined(with: .scale(scale: 1.02))))
                        }
                    }
                }
                .parallax(shift)
                Text(mode.blurb)
                    .font(.body).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(mode)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connect: some View {
        OnboardingPage { _, scroll in
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect an AI").font(.largeTitle.weight(.bold))
                Text("Notestrand works through your own AI account. Pick one; you can add others in Settings any time.")
                    .font(.body).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(AIOption.all) { option in tile(option) }
                }
                // One container that stays put while its contents cross-fade: switching tiles only resizes it,
                // instead of tearing a panel down and sliding a new one in.
                if let option = AIOption.all.first(where: { $0.provider == choice }) {
                    detail(option)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97, anchor: .top)))
                        .id("details")
                }
                safety
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: choice) { picked in
                guard picked != nil else { return }
                // Keep the opened panel on screen; it can land below the fold on a small window.
                withAnimation(Motion.springOrFade) { scroll.scrollTo("details", anchor: .bottom) }
            }
        }
    }

    /// Why pasting a key here is safe, and what to do to limit the risk further.
    private var safety: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                safetyRow("lock.fill", "Kept in the iPad's Keychain, encrypted, on this device only. Never in backups, iCloud or your chats.")
                safetyRow("arrow.up.right", "Sent only to the provider you picked, over an encrypted connection. Notestrand has no server and never sees it.")
                safetyRow("eye.slash", "Never shown again after you save it, and the copy on your clipboard is cleared once it's connected.")
                safetyRow("creditcard", "Tip: make a separate key just for Notestrand, with a monthly spending limit. You can delete it on the provider's site any time.")
            }
            .padding(.top, 8)
        } label: {
            Label("How your key is kept safe", systemImage: "checkmark.shield").font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(Color(.secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func safetyRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.footnote).foregroundColor(.green).frame(width: 18).accessibilityHidden(true)
            Text(text).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connected(_ p: ProviderID) -> Bool { p == .chatgpt ? chatgpt.credentials != nil : saved.contains(p) }

    private func tile(_ option: AIOption) -> some View {
        let selected = choice == option.provider, done = connected(option.provider)
        let tint = option.brand ?? .primary
        return Button {
            withAnimation(Motion.springOrFade) {
                choice = selected ? nil : option.provider
                key = ""
                keyError = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Claude and Gemini ship in their own colours; the single-colour logos take the brand colour.
                    Image(option.logo)
                        .renderingMode(["Logo-claude", "Logo-gemini"].contains(option.logo) ? .original : .template)
                        .resizable().scaledToFit()
                        .foregroundColor(tint)
                        .frame(width: 24, height: 24)
                        .frame(width: 40, height: 40)
                        .background((option.brand ?? Color(.systemGray)).opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)
                    Spacer()
                    if done {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(option.name).font(.headline).foregroundColor(.primary)
                Text(option.badge ?? "API key").font(.caption.weight(.semibold))
                    .foregroundColor(option.badge?.hasPrefix("Free") == true ? .green : .secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? tint.opacity(0.1) : Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? tint : Color(.separator).opacity(0.4), lineWidth: selected ? 2 : 0.5))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(option.name)\(option.badge.map { ", \($0)" } ?? "")\(done ? ", connected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func detail(_ option: AIOption) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if option.provider == .chatgpt {
                Text("Uses your ChatGPT Plus or Pro allowance. You choose how much in ChatGPT Settings → Usage.")
                    .font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let c = chatgpt.credentials {
                    doneLabel("Signed in as \(c.email ?? "your ChatGPT account")")
                } else {
                    Button(action: signIn) {
                        HStack(spacing: 8) {
                            if chatgpt.signingIn { ProgressView() }
                            Text("Continue with ChatGPT").font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(chatgpt.signingIn)
                    ReynardSignIn(chatgpt: chatgpt) { signInError = $0 }
                    if let e = signInError { problem(e) }
                }
            } else if connected(option.provider) {
                doneLabel("\(option.name) is connected")
                Text("Paste a different key below to replace it.").font(.caption).foregroundColor(.secondary)
                keyField(option)
            } else {
                stepRow(1, "Get a key from \(option.name)") {
                    if let url = option.keyURL {
                        Button("Open") { openLink(url) }.buttonStyle(.bordered)
                            .accessibilityLabel("Open \(option.name) key page")
                    }
                }
                stepRow(2, "Paste it here") { EmptyView() }
                keyField(option)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func keyField(_ option: AIOption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SecureField("API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { connectKey(thenAdvance: false) }
                    .padding(12)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityLabel("\(option.name) API key")
                Button {
                    if let s = UIPasteboard.general.string { key = s.trimmed }
                } label: { Image(systemName: "doc.on.clipboard").frame(width: 44, height: 44) }
                .accessibilityLabel("Paste key")
            }
            .modifier(Shake(shakes: shakes))
            Button { connectKey(thenAdvance: false) } label: {
                HStack(spacing: 8) {
                    if checking { ProgressView() }
                    Text(checking ? "Checking…" : "Connect").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(key.trimmed.isEmpty || checking)
            Text(option.provider.keyHint).font(.caption).foregroundColor(.secondary)
            if let e = keyError { problem(e) }
        }
    }

    private func stepRow<Trailing: View>(_ n: Int, _ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundColor(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            Text(text).font(.subheadline.weight(.semibold))
            Spacer()
            trailing()
        }
    }

    private var notes: some View {
        OnboardingPage { shift, _ in
            VStack(alignment: .leading, spacing: 18) {
                NotesGraph(active: page == 3).parallax(shift)
                Text("Your notes become its memory").font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connect your Obsidian vault and the tutor builds on what you've already written. What you learn is saved back as linked notes in a Notestrand folder, so Obsidian's graph grows with you.")
                    .font(.body).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let v = vaultName { doneLabel("Connected: \(v)") }
                Button { pickingVault = true } label: {
                    Label(vaultName == nil ? "Choose vault folder" : "Choose a different folder", systemImage: "folder")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                if let e = vaultError { problem(e) }
                accessChoice
                Text("Optional. You can change this any time in Settings.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Read only or read & write, with the warning shown whenever writing is allowed.
    private var accessChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What can Notestrand do in your vault?").font(.headline)
            HStack(spacing: 10) {
                ForEach(VaultAccess.allCases) { option in
                    let on = vaultAccess == option.rawValue
                    Button { withAnimation(Motion.springOrFade) { vaultAccess = option.rawValue } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: option == .readOnly ? "eye" : "square.and.pencil")
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundColor(on ? .accentColor : .secondary)
                            }
                            Text(option.label).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                            Text(option.summary).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(on ? Color.accentColor.opacity(0.1) : Color(.secondarySystemBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(on ? Color.accentColor : Color(.separator).opacity(0.4), lineWidth: on ? 2 : 0.5))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(option.label). \(option.summary)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if vaultAccess == VaultAccess.readWrite.rawValue {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).accessibilityHidden(true)
                    Text(VaultAccess.writeWarning).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    private var personal: some View {
        OnboardingPage { _, _ in
            VStack(alignment: .leading, spacing: 18) {
                Text("Make it yours").font(.largeTitle.weight(.bold))
                field("What should the tutor call you?") {
                    TextField("Your name", text: $name).textContentType(.givenName).focused($focused)
                }
                field("What are you studying?") {
                    TextField("e.g. A-level Business (AQA)", text: $studying).focused($focused)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pick a colour").font(.headline)
                    AccentPicker()
                }
                summary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            check("AI connected", done: hasAI, hint: "Add one later in Settings")
            check("Obsidian vault", done: vaultName != nil, hint: "Optional")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: pieces

    private func field<F: View>(_ title: String, @ViewBuilder _ input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            input()
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func check(_ title: String, done: Bool, hint: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundColor(done ? .green : .secondary)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if !done { Text(hint).font(.caption).foregroundColor(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    private func doneLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.green)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: actions

    private func finish(celebrate: Bool) {
        focused = false
        let topic = studying.trimmed
        if !topic.isEmpty, !customInstructions.localizedCaseInsensitiveContains(topic) {
            customInstructions = "I'm studying \(topic)." + (customInstructions.isEmpty ? "" : "\n\n" + customInstructions)
        }
        guard celebrate else { return close() }
        Haptics.success()
        withAnimation(Motion.springOrFade) { finishing = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            close()
        }
    }

    private func close() {
        onboarded = true
        app.objectWillChange.send()
        dismiss()
    }

    private func signIn() {
        Task { @MainActor in
            do {
                try await chatgpt.signIn()
                signInError = nil
                Haptics.success()
            } catch { signInError = error.localizedDescription }
        }
    }

    /// Checks the pasted key with the provider before saving it, so a mistyped key never replaces a working one.
    private func connectKey(thenAdvance: Bool) {
        guard let p = choice, p != .chatgpt else { return }
        let k = key.trimmed
        guard !k.isEmpty, !checking else { return }
        focused = false
        checking = true
        keyError = nil
        Task { @MainActor in
            defer { checking = false }
            do { _ = try await ModelCatalog.fetch(p, key: k) } catch {
                keyError = Self.keyRejected(error)
                    ? error.localizedDescription
                    : "Couldn't check the key. \(error.localizedDescription) Try again, or skip for now."
                Haptics.error()
                if !reduceMotion { withAnimation(.linear(duration: 0.4)) { shakes += 1 } }
                return
            }
            let previous = KeyStore.get(p)
            KeyStore.set(p, k)
            guard KeyStore.get(p) == k else {
                KeyStore.set(p, previous ?? "")
                keyError = "Couldn't save the key. Please try again."
                return
            }
            key = ""
            // A copied key sits on the clipboard (and Universal Clipboard) until something replaces it.
            if UIPasteboard.general.string?.trimmed == k { UIPasteboard.general.string = "" }
            Haptics.success()
            withAnimation(Motion.springOrFade) { _ = saved.insert(p) }
            if thenAdvance { page += 1 }
        }
    }

    /// A refused key, as opposed to being offline or the provider being down.
    static func keyRejected(_ error: Error) -> Bool {
        guard let e = error as? LLMError, case .http(let code, _) = e else { return false }
        return [400, 401, 403].contains(code)
    }

    private func connectVault(_ url: URL) {
        do {
            try app.vault.setFolder(url)
            vaultError = nil
            Haptics.success()
            withAnimation(Motion.springOrFade) { vaultName = app.vault.name }
        } catch { vaultError = error.localizedDescription }
    }
}

/// A page of the onboarding: scrolls when its content is tall, centres it when short, and reports how far
/// it is from the centre of the screen so illustrations can lag behind while swiping.
private struct OnboardingPage<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let content: (CGFloat, ScrollViewProxy) -> Content

    var body: some View {
        GeometryReader { geo in
            let shift = reduceMotion ? 0 : geo.frame(in: .global).minX
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    content(shift, proxy)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
    }
}

private extension View {
    /// Moves an illustration at a fraction of the swipe and fades it a little, so it trails its text.
    func parallax(_ shift: CGFloat) -> some View {
        offset(x: -shift * 0.35).opacity(1 - min(abs(shift) / 600, 0.5))
    }
}
