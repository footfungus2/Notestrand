import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var chatgpt = ChatGPTAuth.shared
    @ObservedObject var cards = FlashcardStore.shared
    @State private var reviewing = false
    var start: (SessionKind) -> Void
    var openSettings: () -> Void

    var body: some View {
        let sessions = app.sessions
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let timeGreeting = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        let name = UserDefaults.standard.string(forKey: Prefs.learnerName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let greeting = name.isEmpty ? timeGreeting : "\(timeGreeting), \(name)"
        let hasAPIKey = ProviderID.keyProviders.contains { KeyStore.get($0) != nil }
        let hasChatGPT = chatgpt.credentials != nil
        let hasVault = app.vault.root != nil
        let needsSetup = (!hasAPIKey && !hasChatGPT) || !hasVault
        let lessonCount = app.stats.lessons
        let solvedCount = app.stats.solved
        let knowledgeCount = hasVault ? app.knowledgeCount : nil
        let recentSessions = Array(sessions.sorted { $0.created > $1.created }.prefix(5))
        let relativeDateFormatter = RelativeDateTimeFormatter()

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting)
                        .font(.title2.weight(.bold))
                    Text("What do you want to understand today?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .entrance()

                if needsSetup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get started")
                            .font(.headline)
                            .padding(.bottom, 6)
                        checklistRow("Add an API key or sign in with ChatGPT", done: hasAPIKey || hasChatGPT)
                        checklistRow("Connect your Obsidian vault", done: hasVault)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .entrance(1)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    startCard(.teach, symbol: "graduationcap", description: "Measures what you know, plans a route, checks every step.")
                    startCard(.practice, symbol: "pencil.and.outline", description: "Problems on what you've learned, with hints.")
                    startCard(.exam, symbol: "checkmark.seal", description: "Photograph an answer; it's marked against the official mark scheme.")
                    startCard(.chat, symbol: "bubble.left.and.bubble.right", description: "A normal assistant with your vault as memory.")
                }
                .entrance(2)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    statTile(title: "Sessions", value: "\(sessions.count)")
                    statTile(title: "Lessons", value: "\(lessonCount)")
                    statTile(title: "Problems solved", value: "\(solvedCount)")
                    statTile(title: "Knowledge notes", value: knowledgeCount.map(String.init) ?? "—",
                             caption: hasVault ? nil : "Connect vault")
                }
                .entrance(3)

                Button { reviewing = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle.angled").font(.title2).foregroundColor(.accentColor).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Review flashcards").font(.headline).foregroundColor(.primary)
                            Text(cards.cards.isEmpty ? "Make cards from any chat with the cards button."
                                 : "\(cards.due.count) due · \(cards.cards.count) cards").font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(.secondary).accessibilityHidden(true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PressableStyle())
                .entrance(4)
                .accessibilityLabel("Review flashcards, \(cards.due.count) due")
                .sheet(isPresented: $reviewing) { FlashcardReviewView() }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Continue")
                        .font(.title2.weight(.semibold))
                    if recentSessions.isEmpty {
                        Text("Your recent learning sessions will show up here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 8) {
                            ForEach(recentSessions) { session in
                                sessionRow(session, relativeDate: relativeDateFormatter.localizedString(for: session.created, relativeTo: now))
                            }
                        }
                    }
                }
                .entrance(5)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        // Counted in the background whenever the dashboard comes into view (the vault may have changed).
        .onAppear { app.refreshKnowledgeCount() }
    }

    private func checklistRow(_ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Set up", action: openSettings)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel("Set up: \(title)")
        }
        .padding(.vertical, 7)
    }

    private func startCard(_ kind: SessionKind, symbol: String, description: String) -> some View {
        Button { start(kind) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                Text(kind.label)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(kind.label). \(description)")
    }

    private func statTile(title: String, value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.headline)
            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func sessionRow(_ session: Session, relativeDate: String) -> some View {
        Button {
            app.selected = session.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(for: session.kind))
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(session.kind.label) · \(session.model.label) · \(relativeDate)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Continue \(session.title), \(session.kind.label), \(session.model.label), \(relativeDate)")
    }

    private func symbol(for kind: SessionKind) -> String {
        switch kind {
        case .teach: return "graduationcap"
        case .practice: return "pencil.and.outline"
        case .exam: return "checkmark.seal"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

/// Dashboard numbers, recomputed when sessions change rather than on every redraw.
struct HomeStats: Equatable {
    var lessons = 0
    var solved = 0

    init() {}

    init(_ sessions: [Session]) {
        lessons = sessions.filter { $0.kind == .teach && $0.probeDone }.count
        solved = sessions.reduce(0) { total, session in
            total + session.messages.reduce(0) { sum, message in
                sum + message.toolCalls.filter {
                    $0.name == "conclude" && ["solved", "solvedWithHints"].contains($0.args["outcome"] as? String ?? "")
                }.count
            }
        }
    }
}
