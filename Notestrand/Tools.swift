import Foundation

/// Which agent builds a turn: plain chat, one of LearnHarness's three, or the exam marker.
enum AgentRole: String { case chat, prober, teacher, practice, examiner }

/// Texts copied from LearnHarness core/contracts so the prompts' references line up.
enum LHText {
    static let probeDoneAck = "Assessment recorded — it is shown to the learner now and the teacher plans from it. Say your closing sentence and end your turn; the teaching phase takes over from here."
    static let handoff = "Next: plan the full teaching arc from my current understanding to the goal understanding. Apply the teaching methodology in your system prompt, and find the optimal way to teach me this. Find the unconditional truths, plan the motivated derivations/discoveries, so every reasoning step has to land as obviously true. Take your time here and really think this through. When it's genuinely reasoned out, call plan_init and present the plan; I'll accept it or ask for changes."
    static let planReminder = "These are the plan's node ids — the only valid nodeId values for every quiz and explain call from here on. Reference them exactly."
    static let questionPosed = "Question posed — the turn ends here; the learner's graded answer arrives as this call's result."
    static let problemPosed = "Problem posed — the turn ends here; the learner's thinking traces and answer commits arrive as labeled messages."
    static let concludeAck = "Problem concluded. Say your closing words about the learner's work if useful, then END YOUR TURN — no further tool calls. The next problem is NEVER posed here: it waits for the learner's explicit go-ahead (a *Next problem* message, or their own words asking for the next one). Between problems, answer their questions about the concluded one."
    static let thinkingLabel = "Your thinking"
    static let nextProblem = "Next problem"
    static let chatBase = """
    # The assistant

    You are a helpful, direct assistant in the Notestrand iPad app. Answer the user's questions clearly and accurately. When the user wants to learn something in depth, suggest starting a Teach session from the sidebar.
    """
}

enum Prompts {
    private static let practiceShared: Set<String> = ["10-voice.md", "15-accuracy.md", "16-mental-model.md", "40-formatting.md", "90-ipad.md"]
    private static let examinerShared: Set<String> = ["10-voice.md", "15-accuracy.md", "40-formatting.md", "90-ipad.md"]

    static func fragments(_ dir: String, only: Set<String>? = nil, bundle: Bundle = .main) -> [String] {
        guard let base = bundle.resourceURL?.appendingPathComponent("prompts/\(dir)"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        return files.filter { $0.range(of: #"^\d+-[\w.-]+\.md$"#, options: .regularExpression) != nil && (only?.contains($0) ?? true) }
            .sorted()
            .compactMap { try? String(contentsOf: base.appendingPathComponent($0), encoding: .utf8) }
    }

    private static var cache: [AgentRole: String] = [:]

    /// The bundled prompt for a role, without memory. Bundled files never change, so it's read once.
    static func base(for role: AgentRole, bundle: Bundle = .main) -> String {
        if bundle == .main, let cached = cache[role] { return cached }
        let core = (try? String(contentsOf: bundle.resourceURL!.appendingPathComponent("prompts/system-prompt.md"), encoding: .utf8)) ?? ""
        let parts: [String]
        switch role {
        case .chat: parts = [LHText.chatBase] + fragments("shared", only: ["40-formatting.md", "90-ipad.md"], bundle: bundle)
        case .prober: parts = [core] + fragments("prober", bundle: bundle) + fragments("shared", bundle: bundle)
        case .teacher: parts = [core] + fragments("teacher", bundle: bundle) + fragments("shared", bundle: bundle)
        case .practice: parts = fragments("practice", bundle: bundle) + fragments("shared", only: practiceShared, bundle: bundle)
        case .examiner: parts = fragments("examiner", bundle: bundle) + fragments("shared", only: examinerShared, bundle: bundle)
        }
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
        if bundle == .main { cache[role] = text }
        return text
    }

    static func system(for role: AgentRole, memory: String?, bundle: Bundle = .main) -> String {
        var text = base(for: role, bundle: bundle)
        if !Prefs.webAccessOn { text += "\n\n---\n\nWeb access is turned off in Settings: you can't search or open pages, so say when a fact may be out of date." }
        if Prefs.vaultAccessValue == .readOnly {
            text += "\n\n---\n\nThe learner has made their vault read-only: you can search and read notes but not save anything, so don't offer to."
        }
        if let extra = Prefs.promptAddition { text += "\n\n---\n\n" + extra }
        if let memory, !memory.isEmpty { text += "\n\n---\n\n## Notestrand/Memory.md\n\n" + String(memory.prefix(8000)) }
        return text
    }
}

enum ToolKind { case question, local }

enum Tools {
    struct Def { var spec: ToolSpec; var agents: [String]; var kind: ToolKind }

    static func load(bundle: Bundle = .main) -> [Def] {
        guard let url = bundle.url(forResource: "tools", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["tools"] as? [[String: Any]] else { return [] }
        return list.compactMap { t in
            guard let name = t["name"] as? String, let desc = t["description"] as? String,
                  let schema = t["input_schema"] as? [String: Any] else { return nil }
            return Def(spec: ToolSpec(name: name, description: desc, schema: schema),
                       agents: t["agents"] as? [String] ?? [], kind: t["kind"] as? String == "question" ? .question : .local)
        }
    }

    static let all = load()

    /// Tools for a role, minus any that can't work right now (a weak model retries failing tools forever).
    static func specs(for role: AgentRole, hasVault: Bool = true) -> [ToolSpec] {
        let web = Prefs.webAccessOn
        let provider = Prefs.searchProviderValue
        let canSearch = web && (!provider.needsKey || !(KeyStore.getSecret(provider.secretName) ?? "").isEmpty)
        return all.filter { d in
            let n = d.spec.name
            guard d.agents.contains(role.rawValue) else { return false }
            if n == "web_search" { return canSearch }
            if n == "web_fetch" { return web }
            if n == "vault_write" { return hasVault && Prefs.vaultAccessValue == .readWrite }
            if n.hasPrefix("vault_") || n == "list_sessions" || n == "list_propositions" { return hasVault }
            return true
        }.map(\.spec)
    }

    static func isQuestion(_ name: String) -> Bool {
        all.first { $0.spec.name == name }?.kind == .question && name != "problem"
    }

    // MARK: question validation (mirrors learnharness question-core)

    struct Option { var label: String; var value: String }

    /// Options, healing the double-encoded string some models send.
    static func options(_ args: [String: Any]) -> [Option] {
        var raw = args["options"]
        if let s = raw as? String { raw = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        return (raw as? [[String: Any]] ?? []).compactMap { o in
            guard let label = o["label"] as? String else { return nil }
            return Option(label: label, value: (o["value"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label)
        }
    }

    /// Correct option values, accepting labels too.
    static func correctValues(_ args: [String: Any], _ opts: [Option]) -> [String] {
        let raw: [String] = (args["correctAnswer"] as? [String]) ?? [(args["correctAnswer"] as? String) ?? ""]
        return Array(Set(raw.map { v in opts.first { $0.label == v }?.value ?? v })).filter { !$0.isEmpty }
    }

    /// Problems with a question call, or empty when it can be shown.
    static func problems(_ call: ToolCall, planNodes: [String]) -> [String] {
        let a = call.args
        var out: [String] = []
        if (a["question"] as? String ?? "").isEmpty { out.append("question is required.") }
        let opts = options(a)
        if Set(opts.map(\.value)).count != opts.count { out.append("option values must be unique.") }
        guard call.name == "probe" || call.name == "quiz" else { return out }
        if opts.count < 2 { out.append("a graded question needs at least 2 options.") }
        let correct = correctValues(a, opts)
        if correct.isEmpty { out.append("correctAnswer is required — provide the value (or label) of the correct option(s).") }
        for v in correct where !opts.contains(where: { $0.value == v }) {
            out.append("correctAnswer \"\(v)\" does not match any option value. Valid values: \(opts.map { "\"\($0.value)\"" }.joined(separator: ", ")).")
        }
        if correct.count > 1, a["multiSelect"] as? Bool != true {
            out.append("correctAnswer lists \(correct.count) values but multiSelect is not true. Set multiSelect: true, or make exactly one option correct.")
        }
        if call.name == "quiz" {
            let id = a["nodeId"] as? String ?? ""
            if !planNodes.contains(id) {
                out.append("nodeId \"\(id)\" matches no node in this session's plan map. " +
                           (planNodes.isEmpty ? "No plan map exists yet — call plan_init before posing quizzes."
                                              : "Copy one of your plan_init slugs exactly (\(planNodes.prefix(5).joined(separator: ", "))\(planNodes.count > 5 ? ", …" : "")).") )
            }
            if !["predict", "check"].contains(a["type"] as? String ?? "") { out.append("type must be predict or check.") }
        }
        return out
    }

    static func invalid(_ tool: String, _ problems: [String]) -> String {
        "Invalid tool input for tool \"\(tool)\":\n" + problems.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: plan

    /// Node ids from a mermaid graph block: `slug[Title]` declarations and bare edge endpoints.
    static func planNodes(_ mermaid: String) -> [String] {
        var ids: [String] = []
        for line in mermaid.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || ["graph", "flowchart", "%%", "style", "class", "linkStyle", "```"].contains(where: t.hasPrefix) { continue }
            // Drop node titles and edge labels, then split on arrows: what's left of each piece is an id.
            let bare = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^\)]*\)|\{[^\}]*\}|\|[^|]*\|"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"-\.->|==>|-->|---|&|;"#, with: "\n", options: .regularExpression)
            for piece in bare.components(separatedBy: "\n") {
                let id = piece.trimmingCharacters(in: .whitespaces)
                if !id.isEmpty, !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    static func planProblems(_ ids: [String]) -> [String] {
        if ids.isEmpty { return ["No nodes found. Use one node per line: `slug[Short Title]`, with `-->` edges."] }
        let bad = ids.filter { $0.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) == nil }
        return bad.isEmpty ? [] : ["Node ids must be lowercase slugs (a-z, 0-9, hyphens/underscores): \(bad.joined(separator: ", "))"]
    }
}
