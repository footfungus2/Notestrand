import Foundation

/// The learner's reply to a question card, sent from the web view.
struct CardAnswer: Codable {
    var callId: String
    var values: [String]?
    var other: String?
    var text: String?
    var dontKnow: Bool?
    var dismissed: Bool?
    var confidence: Int?
    var thinking: String?
    var readingThinking: String?
}

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = [] { didSet { stats = HomeStats(sessions) } }
    /// False until saved sessions have been read from disk (the splash screen covers that moment).
    @Published private(set) var loaded = false
    /// True once the splash screen has gone, so first-run onboarding appears above the app, not the splash.
    @Published var launched = false
    @Published private(set) var stats = HomeStats()
    /// Notes in the vault's Knowledge folder, counted off the main thread (nil: no vault, or not counted yet).
    @Published private(set) var knowledgeCount: Int?
    @Published var selected: UUID? {
        didSet { if let s = selected { UserDefaults.standard.set(s.uuidString, forKey: "lastChat") } }
    }
    /// Photos and links shared from other apps, waiting for that chat's message box to pick them up.
    @Published var shared: [UUID: ShareInbox.Item] = [:]
    private var receiveAfterLoad = false
    @Published var streamingText: String?
    /// Reasoning summary streamed so far this turn, for the thinking indicator.
    @Published var streamingReasoning: String?
    /// Text to put in a session's message box when it opens (e.g. after branching).
    @Published var pendingDraft: [UUID: String] = [:]
    @Published var running = false
    @Published var error: String?
    @Published var status: String?
    @Published var notice: String?
    var vault = Vault.shared { didSet { memoryText = vault.appNote("Memory.md") } }
    /// Memory.md as last read; refreshed each turn so the context meter needn't touch iCloud on every redraw.
    private(set) var memoryText: String?

    init() {
        Task { await load() }
    }

    /// Reads saved sessions and Memory.md off the main thread, so the first frame isn't held up by disk or iCloud.
    func load() async {
        let vault = vault
        let (fromDisk, memory) = await Task.detached(priority: .userInitiated) {
            (SessionStore.loadAll(), vault.appNote("Memory.md"))
        }.value
        // Anything created in the meantime is newer than its file, so it wins.
        let inMemory = Set(sessions.map(\.id))
        sessions = (sessions + fromDisk.filter { !inMemory.contains($0.id) }).sorted { $0.created > $1.created }
        if memoryText == nil { memoryText = memory }
        loaded = true
        if receiveAfterLoad { receiveShared() }
    }

    /// Moves anything shared from another app into the chat the learner was last in (or a new chat).
    func receiveShared() {
        // Launched by a share: wait until saved chats are loaded, or there'd be no chat to put it in.
        guard loaded else { receiveAfterLoad = true; return }
        receiveAfterLoad = false
        let items = ShareInbox.takeAll()
        guard !items.isEmpty else { return }
        let last = UserDefaults.standard.string(forKey: "lastChat").flatMap(UUID.init(uuidString:))
        var target = [selected, last].compactMap { $0 }.first { index($0) != nil } ?? sessions.first?.id
        if target == nil, let model = defaultModel {
            newSession(.chat, model: model)
            target = selected
        }
        guard let id = target else {
            items.forEach { try? ShareInbox.put($0) } // kept for after the first chat exists
            notice = "Start a chat first, then your shared photos and links will appear in it."
            return
        }
        var merged = shared[id] ?? ShareInbox.Item()
        for item in items {
            merged.images += item.images
            merged.text = [merged.text, item.text].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        shared[id] = merged
        selected = id
    }

    func refreshKnowledgeCount() {
        let vault = vault
        Task {
            let count = await Task.detached(priority: .utility) { vault.root == nil ? nil : vault.appFolderNotes("Knowledge").count }.value
            if count != knowledgeCount { knowledgeCount = count }
        }
    }
    private var task: Task<Void, Never>?
    /// The session the turn loop is working on, so deleting it can stop the reply.
    private var runningID: UUID?

    var defaultModel: ModelRef? {
        get { UserDefaults.standard.data(forKey: "defaultModel").flatMap { try? JSONDecoder().decode(ModelRef.self, from: $0) } }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "defaultModel") }
    }

    var current: Session? { sessions.first { $0.id == selected } }

    func index(_ id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }

    func newSession(_ kind: SessionKind, model: ModelRef) {
        let s = Session(title: "New \(kind.label.lowercased()) session", kind: kind, model: model)
        sessions.insert(s, at: 0)
        selected = s.id
        persist(s.id)
    }

    func delete(_ s: Session) {
        if runningID == s.id { stop() }
        if selected == s.id { selected = nil }
        sessions.removeAll { $0.id == s.id }
        SessionStore.delete(s)
    }

    func setModel(_ m: ModelRef, for id: UUID) {
        guard let i = index(id) else { return }
        sessions[i].model = m
        defaultModel = m
        persist(id)
        // Nothing is trimmed automatically, so say so before the next turn fails.
        let used = context(for: sessions[i]).used
        if let w = ContextEstimate.window(for: m), used > w {
            notice = "This conversation is about \(ModelCatalog.short(used)) tokens, more than \(m.label)'s \(ModelCatalog.short(w)) context window. Pick a larger model or start a new session."
        }
    }

    func setOptions(effort: Effort?, fast: Bool, for id: UUID) {
        guard let i = index(id) else { return }
        sessions[i].effort = effort
        sessions[i].fast = fast
        persist(id)
    }

    func context(for s: Session) -> ContextBreakdown {
        ContextEstimate.breakdown(s, role: role(s), memory: memoryText)
    }

    func persist(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        SessionStore.saveLater(s) { [weak self] error in self?.error = "Couldn't save the session: \(error.localizedDescription)" }
    }

    private func append(_ m: Message, to id: UUID) {
        guard let i = index(id) else { return }
        sessions[i].messages.append(m)
        persist(id)
    }

    // MARK: user input

    func send(_ text: String, images: [Data] = [], documents: [Attachment] = []) {
        guard let s = current, !running else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty || !documents.isEmpty else { return }
        // Typing past an open question skips it, like LearnHarness's dismissal.
        for call in s.pendingCalls {
            append(Message(role: .tool, text: #"{"kind":"\#(call.name == "ask_user_question" ? "ask" : "quiz")","dismissed":true}"#,
                           toolCallId: call.id, toolName: call.name), to: s.id)
        }
        var body = text
        if s.activeProblem != nil, text != LHText.nextProblem { body = "*\(LHText.thinkingLabel)*\n\n\(text)" }
        if let i = index(s.id), sessions[i].messages.isEmpty {
            sessions[i].title = String((text.isEmpty ? documents.first?.name ?? "Photo" : text).prefix(48))
        }
        var m = Message(role: .user, text: body)
        if !images.isEmpty { m.images = images }
        if !documents.isEmpty { m.documents = documents }
        append(m, to: s.id)
        run(s.id)
    }

    func answer(_ a: CardAnswer) {
        guard let s = current, let call = s.pendingCalls.first(where: { $0.id == a.callId }) else { return }
        let args = call.args
        var out: [String: Any] = ["kind": call.name == "ask_user_question" ? "ask" : "quiz"]
        if a.dismissed == true {
            out["dismissed"] = true
        } else {
            let opts = Tools.options(args)
            let chosen = (a.values ?? []).compactMap { v in opts.firstIndex { $0.value == v } }.sorted()
            if a.dontKnow == true { out["dontKnow"] = true }
            if !chosen.isEmpty { out["answers"] = chosen.map { ["index": $0 + 1, "label": opts[$0].label] } }
            if let o = a.other?.trimmed, !o.isEmpty { out["other"] = o }
            if let t = a.text?.trimmed, !t.isEmpty { out["text"] = t }
            if call.name != "ask_user_question", a.dontKnow != true {
                let correct = Set(Tools.correctValues(args, opts))
                out["correct"] = Set(chosen.map { opts[$0].value }) == correct
                if let c = a.confidence { out["confidence"] = max(0, min(100, c)) }
            }
            if let t = a.thinking?.trimmed, !t.isEmpty { out["thinking"] = t }
            if let t = a.readingThinking?.trimmed, !t.isEmpty { out["thinkingWhileReading"] = t }
        }
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        var m = Message(role: .tool, text: String(decoding: data, as: UTF8.self), toolCallId: call.id, toolName: call.name)
        m.answer = try? JSONEncoder().encode(a)
        append(m, to: s.id)
        if current?.pendingCalls.isEmpty == true { run(s.id) }
    }

    func retry() {
        guard let s = current else { return }
        run(s.id)
    }

    func stop() {
        task?.cancel()
    }

    /// Drops everything after the learner's last input and asks again.
    func regenerate() {
        guard let s = current, !running, let i = index(s.id),
              let last = sessions[i].messages.lastIndex(where: \.isInput) else { return }
        sessions[i].messages.removeSubrange((last + 1)...)
        persist(s.id)
        run(s.id)
    }

    /// Removes the learner's last typed message (and the replies to it) and returns its text for the composer.
    func editLast() -> String? {
        guard let s = current, !running, let i = index(s.id),
              let last = sessions[i].messages.lastIndex(where: \.isInput),
              sessions[i].messages[last].role == .user else { return nil }
        let text = sessions[i].messages[last].text.replacingOccurrences(of: "*\(LHText.thinkingLabel)*\n\n", with: "")
        sessions[i].messages.removeSubrange(last...)
        persist(s.id)
        return text
    }


    // MARK: library: projects, pins, names

    @Published var projects: [Project] = ProjectStore.load()

    private func saveProjects() {
        do { try ProjectStore.save(projects) } catch { self.error = "Couldn't save projects: \(error.localizedDescription)" }
    }

    @discardableResult func createProject(_ name: String) -> Project {
        let p = Project(name: name.trimmed.isEmpty ? "New project" : name.trimmed)
        projects.append(p)
        saveProjects()
        return p
    }

    func updateProject(_ p: Project) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[i] = p
        saveProjects()
    }

    /// Deleting a project keeps its sessions; they move back to "no project".
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        saveProjects()
        for s in sessions where s.projectId == id { setProject(s.id, nil) }
    }

    func setProject(_ sessionID: UUID, _ projectID: UUID?) {
        guard let i = index(sessionID) else { return }
        sessions[i].projectId = projectID
        persist(sessionID)
    }

    func togglePin(_ sessionID: UUID) {
        guard let i = index(sessionID) else { return }
        sessions[i].pinned = sessions[i].pinned == true ? nil : true
        persist(sessionID)
    }

    func rename(_ sessionID: UUID, _ title: String) {
        guard let i = index(sessionID), !title.trimmed.isEmpty else { return }
        sessions[i].title = title.trimmed
        persist(sessionID)
    }

    /// Copies a session up to (not including) a message into a new session, so an earlier turn can be redone
    /// without losing the original. Returns that message's text for the composer.
    func branch(from messageID: UUID) -> String? {
        guard let s = current, let at = s.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        var copy = Session(kind: s.kind, model: s.model)
        copy.title = s.title + " (branch)"
        copy.messages = Array(s.messages[..<at])
        copy.projectId = s.projectId
        copy.effort = s.effort
        copy.fast = s.fast
        sessions.insert(copy, at: 0)
        persist(copy.id)
        selected = copy.id
        return s.messages[at].text.replacingOccurrences(of: "*\(LHText.thinkingLabel)*\n\n", with: "")
    }

    // MARK: /btw

    struct SideQuestion: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var error: String?
    }
    @Published var sideQuestion: SideQuestion?

    /// A quick question about the conversation that isn't added to it.
    func btw(_ question: String) {
        guard let s = current else { return }
        let q = SideQuestion(question: question)
        sideQuestion = q
        let context = s.messages.filter { ($0.role == .user && $0.toolName == nil) || ($0.role == .assistant && !$0.text.isEmpty) }
            .suffix(20).map { "\($0.role == .user ? "Learner" : "Tutor"): \($0.text.prefix(3000))" }.joined(separator: "\n\n")
        let system = "Answer the learner's quick side question briefly and clearly. The conversation is context only: don't continue the lesson or pose questions."
        Task { [weak self] in
            do {
                let a = try await LLMClient.complete(model: s.model, system: system, prompt: "Conversation so far:\n\n\(context)\n\nSide question: \(question)")
                if self?.sideQuestion?.id == q.id { self?.sideQuestion?.answer = a }
            } catch {
                if self?.sideQuestion?.id == q.id { self?.sideQuestion?.error = error.localizedDescription }
            }
        }
    }

    // MARK: the turn loop

    func role(_ s: Session) -> AgentRole {
        switch s.kind {
        case .chat: return .chat
        case .practice: return .practice
        case .exam: return .examiner
        case .teach: return s.probeDone ? .teacher : .prober
        }
    }

    func run(_ id: UUID) {
        guard !running else { return }
        error = nil
        running = true
        runningID = id
        task = Task { [weak self] in
            await self?.loop(id)
            self?.running = false
            self?.runningID = nil
            self?.streamingText = nil; self?.streamingReasoning = nil
        }
    }

    private func loop(_ id: UUID) async {
        var handedOff = false
        var rounds = 0
        while let s = sessions.first(where: { $0.id == id }) {
            rounds += 1
            // Stops a model that keeps calling tools without ever answering.
            if rounds > 12 {
                error = "The model kept using tools without answering, so it was stopped. Try again, or pick a stronger model."
                return
            }
            let wasProbing = s.kind == .teach && !s.probeDone
            let r = role(s)
            let vault = vault
            memoryText = await Task.detached { vault.appNote("Memory.md") }.value
            streamingText = ""
            let tools = Tools.specs(for: r, hasVault: vault.root != nil)
            let reply: Message
            do {
                var system = Prompts.system(for: r, memory: memoryText)
                if let p = projects.first(where: { $0.id == s.projectId }), !p.instructions.trimmed.isEmpty {
                    system += "\n\n---\n\n## Project: \(p.name)\n\n\(p.instructions)"
                }
                reply = try await LLMClient.stream(model: s.model, system: system,
                                                   messages: s.messages, tools: tools,
                                                   options: RequestOptions(effort: s.effort, fast: s.fast ?? false)) { [weak self] t, thinking in
                    self?.streamingText = t
                    self?.streamingReasoning = thinking.isEmpty ? nil : thinking
                }
            } catch {
                if let partial = streamingText, !partial.isEmpty { append(Message(role: .assistant, text: partial), to: id) }
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
                return
            }
            streamingText = nil; streamingReasoning = nil
            append(reply, to: id)

            var waiting = false
            let offered = Set(tools.map(\.name))
            for call in reply.toolCalls {
                // Only tools this turn offered may run. A model can still name one that's switched off
                // (web access, vault writing) or that belongs to another mode.
                if let refusal = Self.refusal(for: call.name, offered: offered) {
                    result(call, refusal, error: true, id)
                } else if Tools.isQuestion(call.name) {
                    let problems = Tools.problems(call, planNodes: sessions.first { $0.id == id }?.plan.map(Tools.planNodes) ?? [])
                    if problems.isEmpty { waiting = true } else { result(call, Tools.invalid(call.name, problems), error: true, id) }
                } else {
                    let (text, isError) = await execute(call, id)
                    result(call, text, error: isError, id)
                    if call.name == "problem", !isError { waiting = true }
                }
            }
            if waiting { return }
            if !reply.toolCalls.isEmpty { continue }
            // The prober has concluded and said goodbye: wake the teacher to plan, as LearnHarness does.
            if wasProbing, sessions.first(where: { $0.id == id })?.probeDone == true, !handedOff {
                handedOff = true
                var m = Message(role: .user, text: LHText.handoff)
                m.toolName = "handoff"
                append(m, to: id)
                continue
            }
            return
        }
    }

    /// The error to return instead of running a tool the turn didn't offer, or nil when it may run.
    nonisolated static func refusal(for tool: String, offered: Set<String>) -> String? {
        offered.contains(tool) ? nil : "The tool \(tool) isn't available here."
    }

    private func result(_ call: ToolCall, _ text: String, error: Bool, _ id: UUID) {
        append(Message(role: .tool, text: text, toolCallId: call.id, toolName: call.name, isError: error), to: id)
    }

    private func execute(_ call: ToolCall, _ id: UUID) async -> (String, Bool) {
        guard let s = sessions.first(where: { $0.id == id }) else { return ("Session not found.", true) }
        let a = call.args
        let vault = vault
        // Vault notes can be iCloud placeholders and a search reads every note, so file work stays off the main thread.
        func offMain<T>(_ work: @escaping () throws -> T) async throws -> T { try await Task.detached(priority: .userInitiated, operation: work).value }
        do {
            switch call.name {
            case "vault_search":
                let query = a["query"] as? String ?? ""
                return (try await offMain { try vault.search(query) }, false)
            case "web_search": return (try await WebTools.search(a["query"] as? String ?? ""), false)
            case "web_fetch": return (try await WebTools.fetch(a["url"] as? String ?? ""), false)
            case "vault_read":
                let path = a["path"] as? String ?? ""
                return (try await offMain { try vault.readNote(path) }, false)
            case "vault_write":
                let path = a["path"] as? String ?? "", content = a["content"] as? String ?? "", append = a["append"] as? Bool ?? false
                try await offMain { try vault.write(path, content: content, append: append) }
                let changed = Vault.inert(content) != content
                return ("Saved Notestrand/\(path)." + (changed ? " Code blocks that Obsidian plugins would run (dataviewjs and similar) were saved as plain code, for safety; tell the learner." : ""), false)
            case "probe_done":
                if s.probeDone { return (Tools.invalid("probe_done", ["The probe is already concluded — probe_done fires exactly once."]), true) }
                if s.pendingCalls.contains(where: { Tools.isQuestion($0.name) }) {
                    return ("A question is still open — resolve it (or let him answer) before concluding the probe. probe_done only fires with no question outstanding.", true)
                }
                return (LHText.probeDoneAck, false)
            case "plan_init":
                let ids = Tools.planNodes(a["mermaid"] as? String ?? "")
                let problems = Tools.planProblems(ids)
                if !problems.isEmpty { return (Tools.invalid("plan_init", problems), true) }
                let out: [String: Any] = ["ok": true, "nodeIds": ids, "reminder": LHText.planReminder]
                return (String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self), false)
            case "problem":
                if s.activeProblem != nil {
                    return (Tools.invalid("problem", ["a problem is already active — call conclude on it before posing the next one"]), true)
                }
                if (a["statement"] as? String ?? "").isEmpty || (a["modelSolution"] as? String ?? "").isEmpty {
                    return (Tools.invalid("problem", ["statement and modelSolution are required."]), true)
                }
                return (LHText.problemPosed, false)
            case "conclude":
                if s.activeProblem == nil { return (Tools.invalid("conclude", ["no problem is active — there is nothing to conclude."]), true) }
                return (LHText.concludeAck, false)
            case "list_sessions": return (try await offMain { Knowledge.listSessions(vault: vault) }, false)
            case "list_propositions":
                let name = a["session"] as? String ?? ""
                if let text = try await offMain({ Knowledge.listPropositions(session: name, vault: vault) }) { return (text, false) }
                return ("No session named \"\(name)\". Use an id exactly as list_sessions reported it.", true)
            default:
                return ("Unknown tool \(call.name).", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    // MARK: knowledge

    func saveToKnowledge() {
        guard let s = current, !running else { return }
        guard vault.root != nil else { error = "Choose your Obsidian vault folder in Settings first."; return }
        running = true
        status = "Saving what you learned to the vault…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false; self.status = nil }
            do {
                let transcript = s.messages.map { m -> String in
                    switch m.role {
                    case .user: return "LEARNER: \(m.text)"
                    case .assistant: return "TUTOR: \(m.text)" + m.toolCalls.map { "\n[\($0.name)] \($0.arguments)" }.joined()
                    case .tool: return "RESULT (\(m.toolName ?? "")): \(m.text)"
                    }
                }.joined(separator: "\n\n")
                let reply = try await LLMClient.complete(model: s.model, system: Knowledge.extractionPrompt, prompt: String(transcript.suffix(300_000)))
                guard let k = Knowledge.parse(reply) else { throw VaultError("The model's reply wasn't valid knowledge JSON. Try again.") }
                let vault = self.vault
                let note = try await Task.detached(priority: .userInitiated) {
                    try Knowledge.save(title: k.title, goal: k.goal, props: k.props, date: s.created, vault: vault)
                }.value
                if let i = self.index(s.id) { self.sessions[i].savedToKnowledge = true; self.persist(s.id) }
                self.status = nil
                self.error = nil
                self.toast = "Saved \(k.props.count) propositions to Notestrand/Sessions/\(note).md"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @Published var toast: String?
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
