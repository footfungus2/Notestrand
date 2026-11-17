import Foundation
import Security

extension ProviderID {
    /// Providers configured with a pasted API key (the ChatGPT plan uses sign-in instead).
    static var keyProviders: [ProviderID] { allCases.filter { $0 != .chatgpt } }

    /// Base URL for a wire format. Chat Completions bases end before `/chat/completions`.
    func baseURL(_ wire: Wire) -> String {
        switch (self, wire) {
        case (.anthropic, _): return "https://api.anthropic.com/v1"
        case (.openai, _), (.chatgpt, _): return "https://api.openai.com/v1"
        case (.gemini, _): return "https://generativelanguage.googleapis.com/v1beta/openai"
        case (.openrouter, _): return "https://openrouter.ai/api/v1"
        case (.opencode, .messages): return "https://opencode.ai/inference/anthropic/v1"
        case (.opencode, .chat), (.opencode, .responses): return "https://opencode.ai/inference/openai/v1"
        case (.custom, _): return Prefs.customServerURL ?? ""
        }
    }

    var keyHint: String {
        switch self {
        case .anthropic: return "console.anthropic.com → API keys"
        case .openai: return "platform.openai.com → API keys"
        case .chatgpt: return "Sign in with ChatGPT below"
        case .gemini: return "aistudio.google.com → Get API key"
        case .openrouter: return "openrouter.ai → Keys"
        case .opencode: return "opencode.ai → Zen → API keys"
        case .custom: return "Optional: only if your server asks for a key"
        }
    }
}

/// API keys live in the Keychain. TrollStore builds without a working
/// keychain entitlement fall back to a file with complete data protection.
enum KeyStore {
    private static let service = "dev.notestrand.ipad.keys"
    /// Keys saved before the rename; read once and copied over.
    private static let oldService = "dev.learnharness.ipad.keys"
    private static var fallbackDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keys")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func get(_ p: ProviderID) -> String? { getSecret(p.rawValue) }
    static func set(_ p: ProviderID, _ key: String) { setSecret(p.rawValue, key) }

    /// Any named secret, e.g. a search provider key ("search.tavily").
    static func getSecret(_ name: String) -> String? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: name, kSecReturnData as String: true]
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return String(data: d, encoding: .utf8)
        }
        var old = q
        old[kSecAttrService as String] = oldService
        if SecItemCopyMatching(old as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let key = String(data: d, encoding: .utf8) {
            setSecret(name, key)
            return key
        }
        return (try? String(contentsOf: fallbackDir.appendingPathComponent(name), encoding: .utf8))
    }

    /// Empty string deletes.
    static func setSecret(_ name: String, _ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: name]
        SecItemDelete(base as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackDir.appendingPathComponent(name))
        guard !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            try? Data(key.utf8).write(to: fallbackDir.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        }
    }
}

/// A model as the picker shows it: grouped by family, newest first.
struct CatalogEntry: Identifiable, Codable {
    var ref: ModelRef
    var group: String
    var created: Date?
    var id: String { ref.id }
}

enum ModelCatalog {
    private static func cacheURL(_ p: ProviderID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("models-\(p.rawValue).json")
    }

    /// The last list fetched for a provider, shown at once while a fresh one loads.
    static func cached(_ p: ProviderID) -> [CatalogEntry] {
        (try? JSONDecoder().decode([CatalogEntry].self, from: Data(contentsOf: cacheURL(p)))) ?? []
    }

    static func remember(_ entries: [CatalogEntry], for p: ProviderID) {
        try? JSONEncoder().encode(entries).write(to: cacheURL(p), options: .atomic)
    }

    /// Fetches the provider's model list. OpenCode reports the wire format per model.
    static func fetch(_ p: ProviderID, key: String? = nil) async throws -> [CatalogEntry] {
        if p == .chatgpt, await ChatGPTAuth.shared.credentials == nil {
            throw AuthError("Sign in with ChatGPT in Settings to see your plan's models.")
        }
        let wire: Wire = p == .anthropic ? .messages : p == .chatgpt ? .responses : .chat
        var url = URL(string: p.baseURL(wire) + "/models")!
        if p == .opencode { url = URL(string: "https://opencode.ai/zen/v1/models")! }
        if p == .anthropic { url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")! }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        // Onboarding checks a new key without replacing a working one in KeyStore.
        let credential: String?
        if let key { credential = key } else { credential = try await LLMClient.credential(for: p) }
        if let credential { LLMClient.authorize(&req, provider: p, wire: wire, key: credential) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(http.statusCode, LLMClient.errorMessage(data))
        }
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if p == .chatgpt {
            // The plan's catalog is {models: [{slug, display_name, visibility}]}, already in OpenAI's order.
            let models = (root["models"] as? [[String: Any]] ?? []).filter { $0["visibility"] as? String == "list" }
            return models.enumerated().compactMap { i, m in
                guard let slug = m["slug"] as? String else { return nil }
                var ref = ModelRef(provider: p, id: slug, wire: .responses, name: m["display_name"] as? String)
                ref.contextWindow = m["context_window"] as? Int
                return CatalogEntry(ref: ref, group: "ChatGPT plan", created: Date(timeIntervalSince1970: Double(models.count - i)))
            }
        }
        return (root["data"] as? [[String: Any]] ?? []).compactMap { entry(p, wire, $0) }
    }

    static func entry(_ p: ProviderID, _ wire: Wire, _ m: [String: Any]) -> CatalogEntry? {
        guard var id = m["id"] as? String else { return nil }
        if id.hasPrefix("models/") { id.removeFirst("models/".count) }
        var ref = ModelRef(provider: p, id: id, wire: wire)
        // Providers use different keys for the same facts.
        ref.name = (m["display_name"] as? String) ?? (m["name"] as? String)
        ref.contextWindow = (m["max_input_tokens"] as? Int) ?? (m["context_length"] as? Int)
            ?? ((m["limit"] as? [String: Any])?["context"] as? Int)
        let created: Date? = (m["created"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (m["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let words = id.split(whereSeparator: { $0 == "-" || $0 == "/" }).map(String.init)

        var group: String
        switch p {
        case .anthropic:
            group = words.count > 1 ? words[1].capitalized : "Other"
        case .chatgpt:
            group = "ChatGPT plan"
        case .openai:
            if ["embedding", "tts", "whisper", "dall-e", "image", "audio", "realtime", "moderation", "transcribe", "search"].contains(where: id.contains) { return nil }
            if id.hasPrefix("gpt-"), words.count > 1 { group = "GPT-" + (words[1].split(separator: ".").first.map(String.init) ?? words[1]) }
            else if id.first == "o", id.dropFirst().first?.isNumber == true { group = "o-series" }
            else { group = "Other" }
        case .gemini:
            if ["embedding", "imagen", "veo", "aqa", "tts"].contains(where: id.contains) { return nil }
            group = words.count > 1 && words[0] == "gemini" ? "Gemini " + (words[1].split(separator: ".").first.map(String.init) ?? words[1]) : (words.first?.capitalized ?? "Other")
        case .openrouter:
            // Names look like "Anthropic: Claude Opus 5.5"; the vendor is the group, the rest the name.
            if let name = ref.name, let colon = name.range(of: ": ") {
                group = String(name[..<colon.lowerBound])
                ref.name = String(name[colon.upperBound...])
            } else {
                group = words.first?.capitalized ?? "Other"
            }
        case .opencode:
            let api = m["api"] as? [String: Any] ?? [:]
            if api["messages"] != nil { ref.wire = .messages }
            else if api["chat-completions"] != nil { ref.wire = .chat }
            else { return nil } // Responses / generate-content models need other wire formats
            group = ref.name?.split(separator: " ").first.map(String.init) ?? words.first?.capitalized ?? "Other"
        case .custom:
            group = "On your server"
        }
        if isFree(p, id, m) { group = "Free" }
        return CatalogEntry(ref: ref, group: group, created: created)
    }

    /// OpenRouter prices are strings ("0"); OpenCode reports a cost object; both also mark free ids.
    static func isFree(_ p: ProviderID, _ id: String, _ m: [String: Any]) -> Bool {
        func zero(_ v: Any?) -> Bool { (v as? String).flatMap(Double.init) == 0 || (v as? Double) == 0 || (v as? Int) == 0 }
        switch p {
        case .openrouter:
            let price = m["pricing"] as? [String: Any] ?? [:]
            return id.hasSuffix(":free") || (zero(price["prompt"]) && zero(price["completion"]))
        case .opencode:
            let cost = m["cost"] as? [String: Any] ?? [:]
            return id.hasSuffix("-free") || (zero(cost["input"]) && zero(cost["output"]))
        default:
            return false
        }
    }

    /// Groups ordered by their newest model, models newest first.
    static func sections(_ entries: [CatalogEntry]) -> [(group: String, models: [CatalogEntry])] {
        let newest: (CatalogEntry, CatalogEntry) -> Bool = {
            ($0.created ?? .distantPast, $1.ref.label) > ($1.created ?? .distantPast, $0.ref.label)
        }
        return Dictionary(grouping: entries, by: \.group)
            .map { (group: $0.key, models: $0.value.sorted(by: newest)) }
            .sorted {
                // Free models first, then families by their newest model.
                if ($0.group == "Free") != ($1.group == "Free") { return $0.group == "Free" }
                return ($0.models.first?.created ?? .distantPast, $1.group) > ($1.models.first?.created ?? .distantPast, $0.group)
            }
    }

    /// "1M", "200K", "162.7K".
    static func short(_ n: Int) -> String {
        func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        if n >= 1_000_000 { return trim(Double(n) / 1_000_000) + "M" }
        if n >= 1_000 { return trim((Double(n) / 100).rounded() / 10) + "K" }
        return String(n)
    }

    /// Wire format for a model id typed by hand.
    static func guessWire(_ p: ProviderID, _ id: String) -> Wire {
        switch p {
        case .anthropic: return .messages
        case .chatgpt: return .responses
        case .opencode: return id.hasPrefix("claude") || id.hasPrefix("qwen3.5") || id.hasPrefix("qwen3.6") || id.hasPrefix("qwen3.8-flash") ? .messages : .chat
        default: return .chat
        }
    }
}
