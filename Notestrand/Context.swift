import SwiftUI

/// What fills a session's context window, Claude Code style.
struct ContextBreakdown {
    struct Part: Identifiable {
        let label: String
        let tokens: Int
        let color: Color
        var id: String { label }
    }

    var parts: [Part]
    var used: Int
    var window: Int?
    /// True when `used` comes from the provider's own token count rather than an estimate.
    var measured: Bool

    var fraction: Double? { window.map { min(1, Double(used) / Double(max($0, 1))) } }
    var free: Int? { window.map { max(0, $0 - used) } }
}

enum ContextEstimate {
    /// Rough tokens for text: about four characters per token.
    static func tokens(_ s: String) -> Int { (s.utf8.count + 3) / 4 }

    static func tokens(_ m: Message) -> Int {
        8 + tokens(m.text) + m.toolCalls.reduce(0) { $0 + tokens($1.name) + tokens($1.arguments) }
    }

    /// Context window when the model list didn't report one.
    static func window(for model: ModelRef) -> Int? {
        if let w = model.contextWindow { return w }
        // Models cached before the plan's context_window was read; Codex gives GPT-5 models 272K.
        if model.provider == .chatgpt { return 272_000 }
        guard model.id.contains("claude") else { return nil }
        // Claude 4.6 and later have 1M; older ones 200K.
        return ["haiku-4", "-4-5", "-4-1", "-4-0", "claude-3"].contains(where: model.id.contains) ? 200_000 : 1_000_000
    }

    static func breakdown(_ s: Session, role: AgentRole, memory: String?) -> ContextBreakdown {
        let system = tokens(Prompts.base(for: role))
        let mem = memory.map { tokens(String($0.prefix(8000))) + 10 } ?? 0
        let specs = Tools.specs(for: role).map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] as [String: Any] }
        let tools = (try? JSONSerialization.data(withJSONObject: specs)).map { ($0.count + 3) / 4 } ?? 0
        let fixed = system + mem + tools

        // The provider's count for the last reply covers everything up to it; estimate only what came after.
        var used: Int, measured = false
        if let k = s.messages.lastIndex(where: { $0.usage != nil }), let u = s.messages[k].usage {
            used = u.total + s.messages[(k + 1)...].reduce(0) { $0 + tokens($1) }
            measured = true
        } else {
            used = fixed + s.messages.reduce(0) { $0 + tokens($1) }
        }
        let messages = max(0, used - fixed)
        used = fixed + messages
        return ContextBreakdown(parts: [
            .init(label: "Messages", tokens: messages, color: .blue),
            .init(label: "Memory.md", tokens: mem, color: .orange),
            .init(label: "Tools", tokens: tools, color: .green),
            .init(label: "System prompt", tokens: system, color: .gray),
        ], used: used, window: window(for: s.model), measured: measured)
    }
}

/// Toolbar ring showing how full the context window is; tap for the breakdown.
struct ContextMeter: View {
    let breakdown: ContextBreakdown
    @State private var showing = false

    var tint: Color {
        guard let f = breakdown.fraction else { return .secondary }
        return f > 0.95 ? .red : f > 0.8 ? .orange : .accentColor
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                    Circle().trim(from: 0, to: breakdown.fraction ?? 0)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                Text(breakdown.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? ModelCatalog.short(breakdown.used))
                    .font(.footnote.monospacedDigit())
            }
        }
        .accessibilityLabel(breakdown.fraction.map { "Context \(Int(($0 * 100).rounded())) percent used" } ?? "Context \(ModelCatalog.short(breakdown.used)) tokens used")
        .popover(isPresented: $showing) { ContextPanel(breakdown: breakdown) }
    }
}

struct ContextPanel: View {
    let breakdown: ContextBreakdown

    private func percent(_ n: Int) -> String {
        guard let w = breakdown.window, w > 0 else { return "" }
        return String(format: "%.1f%%", Double(n) / Double(w) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Context").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(breakdown.fraction.map { "\(Int(($0 * 100).rounded()))% used" } ?? "\(ModelCatalog.short(breakdown.used)) used")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(breakdown.window.map { "\(ModelCatalog.short(breakdown.used)) / \(ModelCatalog.short($0))" } ?? "limit unknown")
                    .font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
            }
            bar
            VStack(spacing: 10) {
                ForEach(breakdown.parts) { part in
                    row(part.label, part.tokens, part.color)
                }
                if let free = breakdown.free { row("Free space", free, Color.secondary.opacity(0.25)) }
            }
            Divider()
            Text("The context window is everything the model can read at once: its instructions, tools, Memory.md and this whole conversation, sent again on every turn. As it fills, replies get slower and the model starts to forget or mix up earlier details, so start a new chat for a new topic. When it's full, the next message won't fit."
                 + (breakdown.measured ? "" : " Figures are estimates until the first reply arrives."))
                .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 360)
    }

    private var bar: some View {
        GeometryReader { geo in
            let total = Double(max(breakdown.window ?? breakdown.used, 1))
            HStack(spacing: 2) {
                ForEach(breakdown.parts.filter { $0.tokens > 0 }) { part in
                    part.color.frame(width: max(3, geo.size.width * Double(part.tokens) / total))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func row(_ label: String, _ tokens: Int, _ color: Color) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12).accessibilityHidden(true)
            Text(label)
            Spacer()
            Text(ModelCatalog.short(tokens)).monospacedDigit()
            Text(percent(tokens)).monospacedDigit().foregroundColor(.secondary).frame(width: 56, alignment: .trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
