import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case anthropic, chatgpt, openai, gemini, openrouter, opencode, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .chatgpt: return "ChatGPT plan"
        case .openai: return "OpenAI (ChatGPT)"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .opencode: return "OpenCode Zen"
        case .custom: return "Your own server (Ollama, LM Studio)"
        }
    }
}

/// Request/stream formats: Anthropic Messages, OpenAI Chat Completions, and OpenAI Responses (ChatGPT plan).
enum Wire: String, Codable { case messages, chat, responses }

struct ModelRef: Codable, Hashable {
    var provider: ProviderID
    var id: String
    var wire: Wire
    var name: String? = nil
    /// Input token limit, when the provider's model list reports it.
    var contextWindow: Int? = nil

    var label: String { name ?? id }
    func same(_ other: ModelRef?) -> Bool { other?.provider == provider && other?.id == id }
}

/// Tokens the provider reported for one reply: everything sent (cached or not) and everything generated.
struct Usage: Codable, Equatable {
    var input: Int
    var output: Int
    var total: Int { input + output }
}

struct ToolCall: Codable, Equatable {
    var id: String
    var name: String
    var arguments: String
    /// Provider fields echoed back unchanged (e.g. Gemini's thought signature), as JSON.
    var extra: Data?

    var args: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
    }
}

enum Role: String, Codable { case user, assistant, tool }

struct Message: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: Role
    var text = ""
    var toolCalls: [ToolCall] = []
    var reasoning: String?
    var toolCallId: String?
    var toolName: String?
    var isError = false
    /// UI-only record of a learner's answer to a question card; never sent to the model.
    var answer: Data?
    var usage: Usage?
    /// Which provider wrote this reply; its provider-specific extras are only echoed back to the same provider.
    var provider: ProviderID?
    /// Claude's content blocks as received (thinking signatures included), replayed unchanged.
    var raw: Data?
    /// nil on messages saved before timestamps existed.
    var created: Date? = Date()
    /// Photos attached by the learner, as JPEG.
    var images: [Data]?
    /// Documents attached by the learner (PDF or text), as extracted text.
    var documents: [Attachment]?
    /// How fast the reply was generated, in output tokens per second (nil before this existed).
    var speed: Double?

    /// What the model reads: attached documents first, then the typed text.
    var textWithDocuments: String {
        let docs = (documents ?? []).map { "<document name=\"\($0.name)\">\n\($0.text)\n</document>" }
        return (docs + [text]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Typed by the learner or answering a card: the point a regenerate rewinds to.
    var isInput: Bool { (role == .user && toolName == nil) || answer != nil }
}

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case chat, teach, practice, exam
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chat: return "Chat"
        case .teach: return "Teach"
        case .practice: return "Practice"
        case .exam: return "Exam"
        }
    }
}

struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New session"
    var kind: SessionKind
    var model: ModelRef
    var messages: [Message] = []
    var created = Date()
    var savedToKnowledge = false
    var effort: Effort?
    var fast: Bool?
    // Optional so sessions saved before these existed still decode.
    var pinned: Bool?
    var projectId: UUID?
    /// When a timed exam attempt ends; nil when no timer is running.
    var examEnds: Date?

    /// A timed attempt is under way, so the examiner invigilates instead of helping.
    func examRunning(at now: Date = Date()) -> Bool { kind == .exam && (examEnds ?? .distantPast) > now }

    /// Teaching hands off from prober to teacher once a probe_done call has a successful result.
    var probeDone: Bool {
        guard kind == .teach else { return false }
        let ids = Set(messages.flatMap { $0.toolCalls.filter { $0.name == "probe_done" }.map(\.id) })
        return messages.contains { $0.role == .tool && !$0.isError && ids.contains($0.toolCallId ?? "") }
    }

    /// The latest successful plan_init mermaid source.
    var plan: String? {
        var ok = Set<String>()
        for m in messages where m.role == .tool && !m.isError && m.toolName == "plan_init" { ok.insert(m.toolCallId ?? "") }
        for m in messages.reversed() {
            if let c = m.toolCalls.last(where: { $0.name == "plan_init" && ok.contains($0.id) }) {
                return c.args["mermaid"] as? String
            }
        }
        return nil
    }

    /// Tool calls still waiting for a result (question cards awaiting the learner).
    var pendingCalls: [ToolCall] {
        guard let i = messages.lastIndex(where: { $0.role == .assistant }) else { return [] }
        let answered = Set(messages[i...].compactMap(\.toolCallId))
        return messages[i].toolCalls.filter { !answered.contains($0.id) }
    }

    /// A practice problem posed and not yet concluded.
    var activeProblem: ToolCall? {
        guard kind == .practice else { return nil }
        var active: ToolCall?
        for m in messages where m.role == .assistant {
            for c in m.toolCalls {
                if c.name == "problem", isSuccess(c) { active = c }
                if c.name == "conclude", isSuccess(c) { active = nil }
            }
        }
        return active
    }

    func isSuccess(_ call: ToolCall) -> Bool {
        messages.contains { $0.role == .tool && $0.toolCallId == call.id && !$0.isError }
    }
}

/// One JSON file per session in Documents/sessions.
struct Attachment: Codable, Equatable {
    var name: String
    var text: String
}

/// A group of sessions with its own standing instructions, like a subject.
struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var instructions = ""
}

enum ProjectStore {
    static var file: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("projects.json") }
    static func load() -> [Project] { (try? JSONDecoder().decode([Project].self, from: Data(contentsOf: file))) ?? [] }
    static func save(_ p: [Project]) throws { try JSONEncoder().encode(p).write(to: file, options: .atomic) }
}

enum SessionStore {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Saves and deletes run here, in order, so disk writes never stall typing or a streaming reply,
    /// and a delete can't be undone by a save that was still waiting.
    static let queue = DispatchQueue(label: "notestrand.sessions", qos: .utility)

    /// Decodes every session file in parallel (they can hold photos, so this is the slow part of launch).
    static func loadAll() -> [Session] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        var decoded = [Session?](repeating: nil, count: files.count)
        decoded.withUnsafeMutableBufferPointer { out in
            // Each iteration writes only its own slot, so the parallel writes never overlap.
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                out[i] = try? JSONDecoder().decode(Session.self, from: Data(contentsOf: files[i]))
            }
        }
        return decoded.compactMap { $0 }.sorted { $0.created > $1.created }
    }

    static func save(_ s: Session) throws {
        try JSONEncoder().encode(s).write(to: dir.appendingPathComponent("\(s.id).json"), options: .atomic)
    }

    /// Saves in the background; a failure is reported back on the main actor.
    static func saveLater(_ s: Session, onError: @escaping @MainActor (Error) -> Void) {
        queue.async {
            do { try save(s) } catch { Task { @MainActor in onError(error) } }
        }
    }

    static func delete(_ s: Session) {
        queue.async { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.id).json")) }
    }

    /// Waits for pending writes, e.g. when the app is about to be suspended.
    static func flush() { queue.sync {} }
}
