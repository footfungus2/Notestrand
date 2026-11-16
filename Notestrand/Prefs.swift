import SwiftUI

/// User preferences, stored in UserDefaults (secrets go through KeyStore instead).
enum Prefs {
    static let onboarded = "onboarded"                   // Bool, welcome and setup completed or skipped
    static let appearance = "appearance"                 // Appearance.rawValue
    static let accent = "accent"                         // Accent.rawValue
    static let customAccent = "customAccent"             // "#rrggbb", used when accent is "custom"
    static let textSize = "textSize"                     // Double, transcript font size in points
    static let customInstructions = "customInstructions" // String, appended to every system prompt
    static let learnerName = "learnerName"               // String
    static let learnerPronouns = "learnerPronouns"       // String, e.g. "they/them"
    static let webAccess = "webAccess"                   // Bool, enables web_search / web_fetch
    static let searchProvider = "searchProvider"         // SearchProvider.rawValue
    static let quickPrompts = "quickPrompts"             // JSON [QuickPrompt]
    static let vaultAccess = "vaultAccess"               // VaultAccess.rawValue
    static let tutorTone = "tutorTone"                   // "", "encouraging" or "direct"
    static let replyLength = "replyLength"               // "", "short" or "detailed"
    static let spelling = "spelling"                     // "", "british" or "american"
    static let studyLevel = "studyLevel"                 // String, e.g. "A-level"
    static let showSpeed = "showSpeed"                   // Bool, tokens per second under replies
    static let haptics = "haptics"                       // Bool
    static let reynardLinks = "reynardLinks"             // Bool, open web links in Reynard instead of Safari
    static let checkUpdates = "checkUpdates"             // Bool, look for a new release on GitHub when the app opens

    static let defaultTextSize = 17.0

    static var d: UserDefaults { .standard }
    static var textSizeValue: Double { d.object(forKey: textSize) as? Double ?? defaultTextSize }
    static var webAccessOn: Bool { d.object(forKey: webAccess) as? Bool ?? true }
    static var accentValue: Accent { Accent(rawValue: d.string(forKey: accent) ?? "") ?? .blue }
    static var vaultAccessValue: VaultAccess { VaultAccess(rawValue: d.string(forKey: vaultAccess) ?? "") ?? .readWrite }
    static var searchProviderValue: SearchProvider { SearchProvider(rawValue: d.string(forKey: searchProvider) ?? "") ?? .free }

    /// Text added to every system prompt from the learner's own settings.
    static var promptAddition: String? {
        var parts: [String] = []
        let name = d.string(forKey: learnerName)?.trimmed ?? ""
        let pronouns = d.string(forKey: learnerPronouns)?.trimmed ?? ""
        if !name.isEmpty || !pronouns.isEmpty {
            var line = "The learner"
            if !name.isEmpty { line += " is called \(name)" }
            if !pronouns.isEmpty { line += (name.isEmpty ? " uses " : " and uses ") + "\(pronouns) pronouns; refer to them that way even where these instructions say \"he\"" }
            parts.append(line + ".")
        }
        let level = d.string(forKey: studyLevel)?.trimmed ?? ""
        if !level.isEmpty { parts.append("Their level of study: \(level). Pitch explanations, vocabulary and examples to that level.") }
        switch d.string(forKey: tutorTone) {
        case "encouraging": parts.append("Be warm and encouraging: notice effort and progress, and keep corrections gentle.")
        case "direct": parts.append("Be direct and to the point: skip praise and pleasantries, and say plainly what is wrong.")
        default: break
        }
        switch d.string(forKey: replyLength) {
        case "short": parts.append("Keep replies short: a few sentences unless they ask for more.")
        case "detailed": parts.append("Give detailed replies with full working and worked examples.")
        default: break
        }
        switch d.string(forKey: spelling) {
        case "british": parts.append("Use British spelling and units (colour, metre, £).")
        case "american": parts.append("Use American spelling (color, meter, $).")
        default: break
        }
        if let custom = d.string(forKey: customInstructions)?.trimmed, !custom.isEmpty { parts.append(custom) }
        return parts.isEmpty ? nil : "## The learner's own instructions\n\n" + parts.joined(separator: "\n\n")
    }
}

/// A saved "/name" command. `{input}` in the template is replaced by whatever follows the command.
struct QuickPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var template: String

    static let defaults = [
        QuickPrompt(name: "explain", template: "Explain {input} simply, step by step, with an everyday example."),
        QuickPrompt(name: "quiz", template: "Quiz me on {input}: ask one question at a time and wait for my answer."),
        QuickPrompt(name: "summarize", template: "Summarise {input} as short revision notes with the key terms in bold."),
        QuickPrompt(name: "eli5", template: "Explain {input} like I'm five."),
    ]

    static var all: [QuickPrompt] {
        get { (Prefs.d.data(forKey: Prefs.quickPrompts)).flatMap { try? JSONDecoder().decode([QuickPrompt].self, from: $0) } ?? defaults }
        set { Prefs.d.set(try? JSONEncoder().encode(newValue), forKey: Prefs.quickPrompts) }
    }

    /// "/explain photosynthesis" → the filled template; nil when the text isn't a saved command.
    static func expand(_ text: String) -> String? {
        let t = text.trimmed
        guard t.hasPrefix("/") else { return nil }
        let name = t.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        guard let p = all.first(where: { $0.name.lowercased() == name }) else { return nil }
        let input = String(t.dropFirst(name.count + 1)).trimmed
        return p.template.replacingOccurrences(of: "{input}", with: input.isEmpty ? "this" : input)
    }
}

/// What Notestrand may do in the learner's Obsidian vault. It can never reach files outside the chosen folder.
enum VaultAccess: String, CaseIterable, Identifiable {
    case readOnly, readWrite
    var id: String { rawValue }
    var label: String { self == .readOnly ? "Read only" : "Read & write" }
    var summary: String {
        self == .readOnly
            ? "Reads your notes. Never creates or changes anything."
            : "Reads your notes, and can create and edit notes in its own Notestrand folder."
    }
    /// The warning shown before allowing writes.
    static let writeWarning = "Notestrand only ever has access to the Obsidian vault folder you choose, never other files on your iPad. With Read & write on, the AI can create and change notes in the vault's Notestrand folder. AI can make mistakes, so keep a backup of your vault (Obsidian Sync, iCloud or Git). Changes you allow are your responsibility."
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

enum Accent: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, green, teal, custom
    var id: String { rawValue }
    /// The fixed swatches; `custom` is the learner's own colour from the colour picker.
    static var presets: [Accent] { allCases.filter { $0 != .custom } }
    var label: String { rawValue.capitalized }
    var color: Color { Color(hex) }
    /// Same colour for the transcript page.
    var hex: String {
        switch self {
        case .blue: return "#2f6fed"
        case .purple: return "#7c4dff"
        case .pink: return "#e0457b"
        case .orange: return "#e8710a"
        case .green: return "#1f8a4c"
        case .teal: return "#0f8b8d"
        case .custom: return Prefs.d.string(forKey: Prefs.customAccent) ?? Accent.blue.hex
        }
    }
}

enum SearchProvider: String, CaseIterable, Identifiable {
    case free, tavily, brave, firecrawl
    var id: String { rawValue }
    var label: String { self == .free ? "Free (DuckDuckGo)" : rawValue.capitalized }
    var needsKey: Bool { self != .free }
    /// Secret name used with KeyStore.getSecret / setSecret.
    var secretName: String { "search.\(rawValue)" }
    var keyHint: String {
        switch self {
        case .free: return "No key needed. Unofficial, so it can be rate-limited; Tavily or Brave are more reliable."
        case .tavily: return "tavily.com → API keys (free tier)"
        case .brave: return "api-dashboard.search.brave.com → API keys (free tier)"
        case .firecrawl: return "firecrawl.dev → API keys"
        }
    }
}

extension Color {
    /// "#rrggbb" in sRGB, for storing a picked colour and handing it to the transcript page.
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) } // extended-range colours clamp to sRGB
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    init(_ hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
