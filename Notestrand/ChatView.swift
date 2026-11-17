import AVFoundation
import SwiftUI
import WebKit

struct ChatView: View {
    @EnvironmentObject var app: AppState
    let sessionId: UUID
    @State private var draft = ""
    @State private var pickingModel = false
    @State private var webError: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(Prefs.textSize) private var textSize = Prefs.defaultTextSize
    @AppStorage(Prefs.showSpeed) private var showSpeed = true
    @AppStorage(Prefs.accent) private var accent = Accent.blue.rawValue
    @AppStorage(Prefs.customAccent) private var customAccent = Accent.blue.hex // repaints when the custom colour changes
    @State private var attachments = PendingAttachments()
    @State private var picker: AttachPicker?
    @State private var attachError: String?
    @State private var share: ShareItem?
    @StateObject private var voice = VoiceInput()
    @State private var makingCards = false
    /// What was typed before dictation started; partial transcripts replace only what follows it.
    @State private var dictationBase: String?

    enum AttachPicker: String, Identifiable { case photos, camera, files, drawing; var id: String { rawValue } }
    struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    var session: Session? { app.sessions.first { $0.id == sessionId } }

    /// The question in "/btw <question>", or nil when the draft isn't a side question.
    var btwQuestion: String? {
        let t = draft.trimmed
        guard t.lowercased() == "/btw" || t.lowercased().hasPrefix("/btw ") else { return nil }
        return String(t.dropFirst(4)).trimmed
    }

    func action(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "copy": UIPasteboard.general.string = body["text"] as? String
        case "speak": Speech.toggle(body["text"] as? String ?? "")
        case "regenerate": app.regenerate()
        case "edit": if let t = app.editLast() { draft = t }
        case "branch":
            // The branch is a new session; its own chat screen picks the text up when it opens.
            if let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)), let t = app.branch(from: id), let new = app.selected {
                app.pendingDraft[new] = t
            }
        default: break
        }
    }

    var body: some View {
        if let s = session {
            VStack(spacing: 0) {
                // Only the chat whose turn is running shows the stream, not whichever chat is open.
                Transcript(session: s, streaming: app.runningID == s.id ? app.streamingText : nil,
                           thinking: app.runningID == s.id ? app.streamingReasoning : nil,
                           style: "LH.style(\(Int(textSize)), '\((Accent(rawValue: accent) ?? .blue).hex)', \(showSpeed))",
                           onAnswer: app.answer, onAction: action, onJSError: { webError = $0 })
                if let q = app.sideQuestion { SideQuestionCard(q: q, close: { app.sideQuestion = nil }) }
                VStack(spacing: 0) { banners }
                    .animation(Motion.spring, value: [app.error, app.toast, app.notice, app.status, voice.error, attachError, webError])
                composer(s)
            }
            .navigationTitle(s.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(s) }
            .sheet(isPresented: $pickingModel) {
                ModelPicker(onPick: { app.setModel($0, for: s.id); pickingModel = false }, current: s.model)
            }
            .sheet(item: $picker) { p in
                switch p {
                case .photos: PhotoPicker { attachments.images += $0 }
                case .camera: CameraPicker { attachments.images.append($0) }.ignoresSafeArea()
                case .drawing: DrawingPad { attachments.images.append($0) }
                case .files: DocumentPicker { r in
                    switch r {
                    case .success(let d): attachments.documents.append(d)
                    case .failure(let e): attachError = e.localizedDescription
                    }
                }
                }
            }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .onAppear {
                app.selected = s.id
                if let d = app.pendingDraft.removeValue(forKey: s.id) { draft = d }
                takeShared()
            }
            .onChange(of: app.shared[s.id] != nil) { if $0 { takeShared() } }
            // Also fires on reopening a chat whose timer ran out while it was closed.
            .task(id: s.examEnds) {
                guard let end = s.examEnds else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(0, end.timeIntervalSinceNow) * 1_000_000_000))
                if !Task.isCancelled { app.endExam(s.id, timeUp: true) }
            }
        }
    }

    @ViewBuilder var banners: some View {
        if let e = app.error {
            let retry: (String, () -> Void)? = app.failedTurn == sessionId ? ("Retry", { app.retry() }) : nil
            Banner(text: e, color: .red, action: retry, close: { app.error = nil })
        }
        if let t = app.toast {
            Banner(text: t, color: .green, action: nil, close: { app.toast = nil })
        }
        if let n = app.notice {
            Banner(text: n, color: .orange, action: nil, close: { app.notice = nil })
        }
        if let s = app.status {
            Banner(text: s, color: .blue, action: nil, close: nil)
        }
        if let v = voice.error {
            Banner(text: v, color: .orange, action: nil, close: { voice.error = nil })
        }
        if let a = attachError {
            Banner(text: a, color: .orange, action: nil, close: { attachError = nil })
        }
        if let w = webError {
            Banner(text: "Display error: \(w)", color: .orange, action: nil, close: { webError = nil })
        }
    }

    @ToolbarContentBuilder func toolbar(_ s: Session) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if s.kind == .exam { examTimer(s) }
            if s.kind == .teach, s.probeDone, Prefs.vaultAccessValue == .readWrite {
                Button { app.saveToKnowledge() } label: {
                    Label(s.savedToKnowledge ? "Saved to knowledge" : "Save to knowledge",
                          systemImage: s.savedToKnowledge ? "books.vertical.fill" : "books.vertical")
                }
                .disabled(app.running)
            }
            Button { makeCards(s) } label: { Image(systemName: "rectangle.on.rectangle.angled") }
                .disabled(makingCards || s.messages.isEmpty)
                .accessibilityLabel("Make flashcards from this chat")
            exportMenu(s)
            ContextMeter(breakdown: app.context(for: s))
            effortMenu(s)
            Button { pickingModel = true } label: {
                if sizeClass == .compact {
                    Image(systemName: "cpu")
                } else {
                    Text(s.model.label).font(.footnote).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
                }
            }
            .accessibilityLabel("Model: \(s.model.label). Change model")
        }
    }

    /// A timed attempt: the examiner invigilates until the learner finishes or time runs out.
    func examTimer(_ s: Session) -> some View {
        Menu {
            if s.examEnds != nil {
                Button { app.endExam(s.id, timeUp: false) } label: { Label("Finish now", systemImage: "stop.circle") }
            } else {
                Section("Timed attempt: no help until you finish") {
                    ForEach([10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { m in
                        Button("\(m) minutes") { app.startExam(minutes: m, for: s.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                if let end = s.examEnds { Text(end, style: .timer).font(.footnote.monospacedDigit()) }
            }
        }
        .accessibilityLabel(s.examEnds.map { "Exam timer, ends at \($0.formatted(date: .omitted, time: .shortened)). Finish now" } ?? "Start a timed attempt")
    }

    /// Photos and links shared from another app land in the message box, ready to send with a question.
    func takeShared() {
        guard let item = app.shared.removeValue(forKey: sessionId) else { return }
        withAnimation(Motion.springOrFade) { attachments.images += item.images }
        if !item.text.isEmpty { draft = draft.isEmpty ? item.text + "\n" : draft + "\n" + item.text }
    }

    func exportMenu(_ s: Session) -> some View {
        Menu {
            Button { exportToVault(s) } label: { Label("Save to vault", systemImage: "square.and.arrow.down") }
                .disabled(app.vault.root == nil || Prefs.vaultAccessValue == .readOnly)
            Button {
                do { share = ShareItem(url: try Export.file(s.title, "md", Data(Export.markdown(s).utf8))) }
                catch { attachError = error.localizedDescription }
            } label: { Label("Share as Markdown", systemImage: "doc.text") }
            Button {
                Transcript.activeWeb?.createPDF { r in
                    switch r {
                    case .success(let data):
                        do { share = ShareItem(url: try Export.file(s.title, "pdf", data)) } catch { attachError = error.localizedDescription }
                    case .failure(let e): attachError = "Couldn't make the PDF: \(e.localizedDescription)"
                    }
                }
            } label: { Label("Share as PDF", systemImage: "doc.richtext") }
        } label: { Image(systemName: "square.and.arrow.up") }
        .accessibilityLabel("Export conversation")
    }

    func makeCards(_ s: Session) {
        makingCards = true
        app.status = "Making flashcards…"
        Task {
            do {
                let cards = try await FlashcardGenerator.generate(from: s)
                FlashcardStore.shared.add(cards)
                app.toast = "Made \(cards.count) flashcards. Review them from Home."
            } catch { attachError = "Couldn't make flashcards: \(error.localizedDescription)" }
            app.status = nil
            makingCards = false
        }
    }

    func exportToVault(_ s: Session) {
        let name = s.title.replacingOccurrences(of: "[/\\\\:?*\"<>|#^\\[\\]]", with: "-", options: .regularExpression).prefix(80)
        do {
            try app.vault.write("Exports/\(name).md", content: Export.markdown(s), append: false)
            app.toast = "Saved to Notestrand/Exports/\(name).md"
        } catch { attachError = error.localizedDescription }
    }

    func effortMenu(_ s: Session) -> some View {
        let fastOK = RequestOptions.fastSupported(s.model)
        let fast = fastOK && s.fast == true
        let effort = Binding<Effort?>(get: { s.effort }, set: { app.setOptions(effort: $0, fast: s.fast ?? false, for: s.id) })
        return Menu {
            Picker("Reasoning effort", selection: effort) {
                Text("Default").tag(Effort?.none)
                ForEach(Effort.allCases) { Text($0.label).tag(Effort?.some($0)) }
            }
            if fastOK {
                Toggle(isOn: Binding(get: { s.fast ?? false }, set: { app.setOptions(effort: s.effort, fast: $0, for: s.id) })) {
                    Label("Fast mode (costs more)", systemImage: "hare")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: fast ? "hare.fill" : "brain")
                if sizeClass != .compact { Text(s.effort?.label ?? "Effort").font(.footnote) }
            }
        }
        .accessibilityLabel("Reasoning effort: \(s.effort?.label ?? "default")\(fast ? ", fast mode on" : "")")
    }

    func composer(_ s: Session) -> some View {
        let practicePause = s.kind == .practice && s.activeProblem == nil && s.messages.contains { $0.toolCalls.contains { $0.name == "conclude" } }
        let placeholder: String = {
            if s.activeProblem != nil { return "Your thinking: work through the problem, ask for a hint, or give your answer" }
            if !s.pendingCalls.isEmpty { return "Answer the question above, or type to skip it" }
            if s.examEnds != nil { return "Timer running: answer on paper, then tap the timer to finish" }
            switch s.kind {
            case .teach: return s.messages.isEmpty ? "What do you want to understand?" : "Reply, or /btw to ask on the side"
            case .practice: return s.messages.isEmpty ? "What do you want to practise? A topic, or a session from your knowledge map" : "Ask about the problem…"
            case .exam: return s.messages.isEmpty ? "Tap + to photograph the question and your answer, then send" : "Ask about the marking, or rewrite part of your answer"
            case .chat: return s.messages.isEmpty ? "Message Notestrand" : "Message, or /btw to ask on the side"
            }
        }()
        return VStack(spacing: 8) {
            if practicePause, !app.running {
                Button(LHText.nextProblem) { app.send(LHText.nextProblem) }.buttonStyle(.bordered)
            }
            commandSuggestions
            VStack(alignment: .leading, spacing: 2) {
                if !attachments.isEmpty { attachmentStrip.transition(.opacity) }
                if btwQuestion != nil {
                    Label("Side question · not added to the chat", systemImage: "bubble.left")
                        .font(.caption.weight(.semibold)).foregroundColor(.accentColor).padding(.top, 4)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    attachMenu
                    TextEditor(text: $draft)
                        .clearEditorBackground()
                        .frame(minHeight: 38, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(placeholder)
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text(placeholder).foregroundColor(.secondary).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 8)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                    MicButton(voice: voice) { text in
                        if dictationBase == nil { dictationBase = draft.isEmpty ? "" : draft + " " }
                        draft = (dictationBase ?? "") + text
                    }
                    .onChange(of: voice.isRecording) { if !$0 { dictationBase = nil } }
                    // A /btw side question can be sent even while a reply is streaming.
                    if app.runningID == s.id && btwQuestion == nil {
                        roundButton("stop.fill", enabled: true, label: "Stop") { app.stop() }
                    } else {
                        // While another chat is replying, only a side question can go: one turn runs at a time.
                        roundButton("arrow.up", enabled: (!draft.trimmed.isEmpty || !attachments.isEmpty) && btwQuestion?.isEmpty != true
                                        && (btwQuestion != nil || !app.running),
                                    label: btwQuestion == nil ? "Send" : "Ask side question") {
                            if let q = btwQuestion { app.btw(q) } else {
                                app.send(QuickPrompt.expand(draft) ?? draft, images: attachments.images, documents: attachments.documents)
                                attachments = PendingAttachments()
                            }
                            draft = ""
                        }
                    }
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color(.separator).opacity(0.5), lineWidth: 0.5))
            .frame(maxWidth: 780)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .animation(Motion.spring, value: attachments.images.count + attachments.documents.count)
    }

    var attachMenu: some View {
        Menu {
            Button { picker = .photos } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
            if CameraPicker.available {
                Button { picker = .camera } label: { Label("Take photo", systemImage: "camera") }
            }
            Button { picker = .files } label: { Label("PDF or text file", systemImage: "doc") }
            Button { picker = .drawing } label: { Label("Draw your working", systemImage: "pencil.tip.crop.circle") }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundColor(.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Attach photo, file or drawing")
    }

    var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.images.enumerated()), id: \.offset) { i, data in
                    ZStack(alignment: .topTrailing) {
                        if let img = UIImage(data: data) {
                            Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        removeButton("Remove photo \(i + 1)") { attachments.images.remove(at: i) }
                    }
                }
                ForEach(Array(attachments.documents.enumerated()), id: \.offset) { i, d in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundColor(.accentColor)
                        Text(d.name).font(.caption).lineLimit(1).frame(maxWidth: 140)
                        removeButton("Remove \(d.name)") { attachments.documents.remove(at: i) }
                    }
                    .padding(.leading, 10).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemBackground)))
                }
            }
            .padding(.top, 6)
        }
    }

    func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundColor(.secondary)
                .background(Circle().fill(Color(.systemBackground)))
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// While typing "/name", show matching quick prompts and /btw.
    @ViewBuilder var commandSuggestions: some View {
        let t = draft.trimmed
        if t.hasPrefix("/"), !t.contains(" ") {
            let typed = t.dropFirst().lowercased()
            let all = [("btw", "Side question, not added to the chat")] + QuickPrompt.all.map { ($0.name, $0.template) }
            let matches = all.filter { typed.isEmpty || $0.0.lowercased().hasPrefix(typed) }
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matches, id: \.0) { name, hint in
                            Button { draft = "/\(name) " } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("/\(name)").font(.subheadline.weight(.semibold))
                                    Text(hint).font(.caption2).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(Color(.secondarySystemBackground)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("/\(name): \(hint)")
                        }
                    }
                }
                .frame(maxWidth: 780)
            }
        }
    }

    func roundButton(_ symbol: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(enabled ? Color.accentColor : Color(.systemGray3)))
                .frame(width: 44, height: 44) // full-size touch target around the 34pt circle
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

extension View {
    /// TextEditor draws its own opaque background on iOS 16+; hide it so the rounded field shows through.
    @ViewBuilder func clearEditorBackground() -> some View {
        if #available(iOS 16, *) { scrollContentBackground(.hidden) } else { self }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    let action: (String, () -> Void)?
    let close: (() -> Void)?
    var body: some View {
        HStack {
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let action { Button(action.0, action: action.1).buttonStyle(.bordered) }
            if let close { Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Dismiss") }
        }
        .padding(10)
        .background(color.opacity(0.12))
        .transition(.opacity)
    }
}

/// Read aloud with the system voice; a second tap stops.
enum Speech {
    private static let synth = AVSpeechSynthesizer()

    static func toggle(_ markdown: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate); return }
        // Code, maths and diagrams read badly aloud, so they're skipped.
        var t = markdown.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\$\\$[\\s\\S]*?\\$\\$|\\$[^$\\n]+\\$", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#`>|]", with: "", options: .regularExpression)
        synth.speak(AVSpeechUtterance(string: t))
    }
}

/// The /btw answer: shown above the composer, never added to the conversation.
struct SideQuestionCard: View {
    let q: AppState.SideQuestion
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Side question", systemImage: "bubble.left").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .accessibilityLabel("Close side question")
            }
            Text(q.question).font(.subheadline.weight(.semibold))
            ScrollView {
                Group {
                    if let a = q.answer { Text(.init(a)).textSelection(.enabled).webLinksOnly() }
                    else if let e = q.error { Text(e).foregroundColor(.red) }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Text("Not added to the conversation.").font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 12).padding(.top, 6)
    }
}

/// The transcript is one local HTML page: markdown, KaTeX and Mermaid render there.
/// Each chat screen owns its web view; moving one between screens mid-touch crashes UIKit.
struct Transcript: UIViewRepresentable {
    /// The most recently shown transcript, for PDF export.
    static weak var activeWeb: WKWebView?
    let session: Session
    let streaming: String?
    /// Reasoning summary so far, shown under the thinking animation.
    var thinking: String? = nil
    /// JavaScript applying the learner's text size and accent.
    let style: String
    let onAnswer: (CardAnswer) -> Void
    /// Message action bar taps: copy, speak, regenerate, edit.
    let onAction: ([String: Any]) -> Void
    let onJSError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(TranscriptHost.noWebRTC)
        config.userContentController.add(context.coordinator, name: "lh")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        context.coordinator.web = web
        Transcript.activeWeb = web
        TranscriptHost.shared.whenRulesReady { [weak web] rules in
            // Load only once remote blocking is in place.
            guard let rules else { return onJSError("Couldn't set up the transcript's network block.") }
            config.userContentController.add(rules)
            web?.loadFileURL(TranscriptHost.page, allowingReadAccessTo: TranscriptHost.page.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push()
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "lh")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: Transcript
        weak var web: WKWebView?
        private var loaded = false
        private var lastSession: Session?
        private var lastRunning: Bool?
        private var lastStreaming: String??
        private var lastThinking: String?
        private var lastStyle: String?

        init(_ p: Transcript) { parent = p }

        /// Sends the session to the page when it changed since the last push.
        func push() {
            guard loaded else { return }
            if parent.style != lastStyle {
                lastStyle = parent.style
                run(parent.style)
            }
            // Comparing is far cheaper than re-encoding every message (photos included) on each streamed update.
            let running = parent.streaming != nil
            if parent.session != lastSession || running != lastRunning {
                lastSession = parent.session
                lastRunning = running
                var obj: [String: Any] = ["id": parent.session.id.uuidString, "kind": parent.session.kind.rawValue,
                                          "pending": parent.session.pendingCalls.map(\.id), "running": running]
                if let msgs = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(parent.session.messages)) { obj["messages"] = msgs }
                if let data = try? JSONSerialization.data(withJSONObject: obj) {
                    run("LH.render(\(String(decoding: data, as: UTF8.self)))")
                }
            }
            // The page shows the last readable line of reasoning; send just the last few to keep pushes small.
            let tail = parent.thinking.map { $0.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n") }
            if lastStreaming != .some(parent.streaming) || tail != lastThinking {
                lastStreaming = .some(parent.streaming)
                lastThinking = tail
                let s = parent.streaming.flatMap { try? JSONSerialization.data(withJSONObject: [$0]) }
                let t = tail.flatMap { try? JSONSerialization.data(withJSONObject: [$0]) }
                run("LH.stream(\(s.map { String(decoding: $0, as: UTF8.self) + "[0]" } ?? "null"), \(t.map { String(decoding: $0, as: UTF8.self) + "[0]" } ?? "null"))")
            }
        }

        /// Exceptions thrown inside evaluateJavaScript never reach window.onerror, so report them here.
        private func run(_ js: String) {
            web?.evaluateJavaScript(js + ";0") { [weak self] _, error in
                guard let error = error as NSError? else { return }
                self?.parent.onJSError(error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
            }
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            lastSession = nil // a (re)loaded page starts empty
            push()
        }

        // Only the bundled page may load; links open in Safari or Reynard.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let (policy, link) = Self.decide(action.request.url, type: action.navigationType,
                                             fromMainFrame: action.sourceFrame.isMainFrame, toMainFrame: action.targetFrame?.isMainFrame)
            if let link { openLink(link) }
            decisionHandler(policy)
        }

        /// Whether a navigation may load in the page, and the web link to open in a browser instead, if any.
        static func decide(_ url: URL?, type: WKNavigationType, fromMainFrame: Bool, toMainFrame: Bool?) -> (WKNavigationActionPolicy, open: URL?) {
            // The bundled page, in the main frame only: a "#" link inside a demo resolves to the app's page and would replace the demo with it.
            if url?.isFileURL == true, toMainFrame == true { return (.allow, nil) }
            // Sandboxed demo frames load from about:srcdoc.
            if toMainFrame == false, url?.scheme == "about" { return (.allow, nil) }
            // A demo can click its own links from script, so only links in the conversation itself open a browser.
            // Otherwise a model-written demo could send data out in an address without the learner tapping anything.
            if type == .linkActivated, fromMainFrame, let url, ["http", "https"].contains(url.scheme) { return (.cancel, url) }
            return (.cancel, nil)
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            // Model-written demos run in sandboxed iframes that can still reach this handler: only the page itself may answer or act.
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "answer":
                if let a = body["answer"], let data = try? JSONSerialization.data(withJSONObject: a),
                   let answer = try? JSONDecoder().decode(CardAnswer.self, from: data) {
                    parent.onAnswer(answer)
                }
            case "copy", "speak", "regenerate", "edit", "branch":
                parent.onAction(body)
            case "error":
                parent.onJSError(body["message"] as? String ?? "unknown")
            default: break
            }
        }
    }
}

/// Shared WebKit set-up. Starting the web content process and parsing ~3 MB of Mermaid takes seconds,
/// so a hidden page warms both at launch; on iOS 15+ every web view shares that process.
final class TranscriptHost {
    static let shared = TranscriptHost()
    static let page = Bundle.main.resourceURL!.appendingPathComponent("web/chat.html")
    private var warm: WKWebView?
    private var rules: WKContentRuleList?
    private var compiled = false
    private var waiting: [(WKContentRuleList?) -> Void] = []

    /// Blocks every load that isn't a bundled file, so model output or vault notes can't reach the network.
    /// about: (sandboxed demo frames) and data:image (attached photos) are allowed; neither reaches the network.
    /// Content rules don't cover WebRTC: a demo could open a peer connection to any server and send data in it.
    /// This runs first in every frame, nested ones included, and removes those APIs before any page script.
    static let noWebRTC = WKUserScript(source: """
        (function () {
          ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCSessionDescription", "RTCIceCandidate", "WebTransport"].forEach(function (k) {
            try { Object.defineProperty(window, k, { value: undefined, writable: false, configurable: false }); } catch (e) {}
          });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    private static let ruleID = "block-remote-v3"
    private static let blockRemote = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^data:image/"},"action":{"type":"ignore-previous-rules"}}]"#

    private init() {
        let store = WKContentRuleListStore.default()!
        store.lookUpContentRuleList(forIdentifier: Self.ruleID) { [weak self] cached, _ in
            if let cached { return self?.ready(cached) ?? () }
            store.compileContentRuleList(forIdentifier: Self.ruleID, encodedContentRuleList: Self.blockRemote) { list, _ in
                self?.ready(list)
            }
        }
    }

    private func ready(_ list: WKContentRuleList?) {
        rules = list
        compiled = true
        waiting.forEach { $0(list) }
        waiting = []
        guard let list else { return }
        let config = WKWebViewConfiguration()
        config.userContentController.add(list)
        warm = WKWebView(frame: .zero, configuration: config)
        warm?.loadFileURL(Self.page, allowingReadAccessTo: Self.page.deletingLastPathComponent())
    }

    func whenRulesReady(_ f: @escaping (WKContentRuleList?) -> Void) {
        if compiled { f(rules) } else { waiting.append(f) }
    }
}
