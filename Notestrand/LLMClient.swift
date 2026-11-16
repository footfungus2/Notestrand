import Foundation

enum LLMError: LocalizedError {
    case noKey(ProviderID)
    case http(Int, String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .noKey(let p): return "No API key for \(p.label). Add one in Settings."
        case .http(401, let body), .http(403, let body):
            return "The provider rejected the API key (\(body)). Check the key in Settings: it must be an API key from the provider's developer console, not a ChatGPT or Claude subscription login."
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .stream(let msg): return msg
        }
    }
}

/// A tool as sent to the model.
struct ToolSpec {
    var name: String
    var description: String
    var schema: [String: Any]
}

/// Accumulates one assistant reply from SSE `data:` lines.
protocol StreamParser {
    var text: String { get }
    var reasoning: String { get }
    var toolCalls: [ToolCall] { get }
    var error: String? { get }
    var usage: Usage? { get }
    /// The reply's content blocks exactly as the provider sent them, when they must be replayed unchanged.
    var raw: Data? { get }
    /// False when the stream ended before the provider's terminal event.
    var finished: Bool { get }
    mutating func feed(_ line: String)
}

extension StreamParser {
    var finished: Bool { true }
}

/// Per-session generation settings.
enum Effort: String, Codable, CaseIterable, Identifiable {
    case off, low, medium, high, max
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct RequestOptions {
    var effort: Effort?
    var fast = false

    /// Fast mode exists for Claude Opus 5.5 / 5 / 4.8 on the Anthropic API, OpenAI's priority tier,
    /// and OpenRouter's throughput routing.
    static func fastSupported(_ m: ModelRef) -> Bool {
        switch m.provider {
        case .anthropic: return ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"].contains(m.id)
        case .openai, .openrouter: return true
        case .gemini, .opencode, .chatgpt: return false
        }
    }
}

struct AnthropicParser: StreamParser {
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var error: String?
    private(set) var usage: Usage?
    private var calls: [Int: ToolCall] = [:]
    private var order: [Int] = []
    private var blocks: [Int: [String: Any]] = [:]
    var toolCalls: [ToolCall] { order.compactMap { calls[$0] } }

    /// Claude's thinking blocks (with signatures) must go back unchanged, so keep every block as sent.
    var raw: Data? {
        let content = blocks.keys.sorted().compactMap { i -> [String: Any]? in
            guard var b = blocks[i] else { return nil }
            if b["type"] as? String == "tool_use" { b["input"] = calls[i]?.args ?? [:] }
            return b
        }
        return content.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: content)
    }

    private mutating func extend(_ i: Int, _ key: String, _ s: String) {
        let old = blocks[i]?[key] as? String ?? ""
        blocks[i]?[key] = old + s
    }

    mutating func feed(_ line: String) {
        guard line.hasPrefix("data:"), let o = json(line.dropFirst(5)) else { return }
        let index = o["index"] as? Int ?? 0
        switch o["type"] as? String {
        case "message_start":
            // Cached and uncached input together are what the context window holds.
            let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
            let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
            usage = Usage(input: input, output: u["output_tokens"] as? Int ?? 0)
        case "message_delta":
            if let out = (o["usage"] as? [String: Any])?["output_tokens"] as? Int { usage?.output = out }
        case "content_block_start":
            guard let b = o["content_block"] as? [String: Any] else { return }
            blocks[index] = b
            if b["type"] as? String == "tool_use" {
                calls[index] = ToolCall(id: b["id"] as? String ?? UUID().uuidString, name: b["name"] as? String ?? "", arguments: "")
                order.append(index)
            }
        case "content_block_delta":
            let d = o["delta"] as? [String: Any] ?? [:]
            switch d["type"] as? String {
            case "text_delta":
                let t = d["text"] as? String ?? ""
                text += t
                extend(index, "text", t)
            case "thinking_delta":
                let t = d["thinking"] as? String ?? ""
                reasoning += t
                extend(index, "thinking", t)
            case "signature_delta":
                extend(index, "signature", d["signature"] as? String ?? "")
            case "input_json_delta": calls[index]?.arguments += d["partial_json"] as? String ?? ""
            default: break
            }
        case "error":
            error = (o["error"] as? [String: Any])?["message"] as? String ?? "Stream error"
        default: break
        }
    }
}

struct OpenAIParser: StreamParser {
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var error: String?
    private(set) var usage: Usage?
    private var calls: [Int: ToolCall] = [:]
    var toolCalls: [ToolCall] { calls.keys.sorted().compactMap { calls[$0] } }
    var raw: Data? { nil }

    mutating func feed(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let o = json(Substring(payload)) else { return }
        if let e = o["error"] as? [String: Any] { error = e["message"] as? String ?? "Stream error"; return }
        // Usage arrives in its own final chunk, which has no choices.
        if let u = o["usage"] as? [String: Any], let input = u["prompt_tokens"] as? Int {
            usage = Usage(input: input, output: u["completion_tokens"] as? Int ?? 0)
        }
        guard let choice = (o["choices"] as? [[String: Any]])?.first, let d = choice["delta"] as? [String: Any] else { return }
        text += d["content"] as? String ?? ""
        reasoning += (d["reasoning_content"] as? String) ?? (d["reasoning"] as? String) ?? ""
        for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
            let i = tc["index"] as? Int ?? calls.count
            var call = calls[i] ?? ToolCall(id: "", name: "", arguments: "")
            if let id = tc["id"] as? String, !id.isEmpty { call.id = id }
            let f = tc["function"] as? [String: Any] ?? [:]
            if let n = f["name"] as? String { call.name += n }
            call.arguments += f["arguments"] as? String ?? ""
            // Anything beyond the standard keys (e.g. Gemini's extra_content) is echoed back later.
            let extra = tc.filter { !["index", "id", "type", "function"].contains($0.key) }
            if !extra.isEmpty { call.extra = try? JSONSerialization.data(withJSONObject: extra) }
            calls[i] = call
        }
    }
}

/// OpenAI Responses API stream (the ChatGPT plan route).
struct ResponsesParser: StreamParser {
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var error: String?
    private(set) var usage: Usage?
    private(set) var finished = false
    private var items: [Int: [String: Any]] = [:]
    static let namespace = "notestrand"

    var toolCalls: [ToolCall] {
        items.keys.sorted().compactMap { i -> ToolCall? in
            guard let it = items[i], it["type"] as? String == "function_call", let id = it["call_id"] as? String else { return nil }
            var name = it["name"] as? String ?? ""
            if name.hasPrefix(Self.namespace + ".") { name.removeFirst(Self.namespace.count + 1) }
            return ToolCall(id: id, name: name, arguments: it["arguments"] as? String ?? "{}")
        }
    }

    /// Output items to replay as input: reasoning keeps its encrypted content; ids and statuses of
    /// other items refer to stored responses, which this route never creates (store: false).
    var raw: Data? {
        let out = items.keys.sorted().compactMap { i -> [String: Any]? in
            guard var it = items[i] else { return nil }
            it["status"] = nil
            if it["type"] as? String != "reasoning" { it["id"] = nil }
            return it
        }
        return out.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: out)
    }

    mutating func feed(_ line: String) {
        guard line.hasPrefix("data:"), let o = json(line.dropFirst(5)) else { return }
        switch o["type"] as? String {
        case "response.output_text.delta":
            text += o["delta"] as? String ?? ""
        case "response.reasoning_summary_text.delta":
            reasoning += o["delta"] as? String ?? ""
        case "response.output_item.done":
            if let item = o["item"] as? [String: Any] { items[o["output_index"] as? Int ?? items.count] = item }
        case "response.completed":
            let r = o["response"] as? [String: Any] ?? [:]
            if let u = r["usage"] as? [String: Any], let input = u["input_tokens"] as? Int {
                usage = Usage(input: input, output: u["output_tokens"] as? Int ?? 0)
            }
            if items.isEmpty {
                for (i, item) in (r["output"] as? [[String: Any]] ?? []).enumerated() { items[i] = item }
            }
            finished = true
        case "response.failed":
            let e = (o["response"] as? [String: Any])?["error"] as? [String: Any] ?? [:]
            error = Self.describe(code: e["code"] as? String, message: e["message"] as? String)
        case "response.incomplete":
            let reason = ((o["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown"
            error = "The reply was cut off (\(reason))."
        case "error":
            let e = o["error"] as? [String: Any] ?? o
            error = Self.describe(code: e["code"] as? String, message: e["message"] as? String)
        default: break
        }
    }

    static func describe(code: String?, message: String?) -> String {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return "Notestrand has used its ChatGPT plan allowance for now. Raise its limit in ChatGPT Settings → Usage, or wait for it to reset."
        case "subscription_sharing_usage_unavailable":
            return "ChatGPT plan usage isn't available for this account right now. Check ChatGPT Settings → Usage."
        default:
            return message ?? code ?? "The response failed."
        }
    }
}

private func json(_ s: Substring) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(s.trimmingCharacters(in: .whitespaces).utf8))) as? [String: Any]
}

enum LLMClient {
    /// The credential for a provider: a pasted key, or a fresh ChatGPT access token.
    static func credential(for p: ProviderID) async throws -> String? {
        if p == .chatgpt { return await ChatGPTAuth.shared.credentials == nil ? nil : try await ChatGPTAuth.shared.accessToken() }
        return KeyStore.get(p)
    }

    static func authorize(_ req: inout URLRequest, provider: ProviderID, wire: Wire, key: String) {
        if wire == .messages {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if provider == .opencode { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if provider == .openrouter {
            req.setValue("Notestrand", forHTTPHeaderField: "X-Title")
        }
    }

    // MARK: request bodies

    static func messagesBody(model: String, system: String, messages: [Message], tools: [ToolSpec],
                             provider: ProviderID = .anthropic, options: RequestOptions = .init()) -> [String: Any] {
        var out: [[String: Any]] = []
        func push(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if out.last?["role"] as? String == role {
                out[out.count - 1]["content"] = (out[out.count - 1]["content"] as! [[String: Any]]) + blocks
            } else {
                out.append(["role": role, "content": blocks])
            }
        }
        for m in messages {
            switch m.role {
            case .user:
                var blocks: [[String: Any]] = (m.images ?? []).map {
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
                }
                let text = m.textWithDocuments
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                push("user", blocks)
            case .assistant:
                // Same provider: replay its blocks untouched, thinking signatures included.
                if m.provider == provider, let raw = m.raw,
                   let blocks = (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] {
                    push("assistant", blocks)
                    continue
                }
                var blocks: [[String: Any]] = m.text.isEmpty ? [] : [["type": "text", "text": m.text]]
                for c in m.toolCalls { blocks.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.args]) }
                push("assistant", blocks)
            case .tool:
                var b: [String: Any] = ["type": "tool_result", "tool_use_id": m.toolCallId ?? "", "content": m.text]
                if m.isError { b["is_error"] = true }
                push("user", [b])
            }
        }
        // Cache the long teaching prompt and the conversation so far.
        if var last = out.last?["content"] as? [[String: Any]], !last.isEmpty {
            last[last.count - 1]["cache_control"] = ["type": "ephemeral"]
            out[out.count - 1]["content"] = last
        }
        var body: [String: Any] = [
            "model": model, "max_tokens": 16000, "stream": true, "messages": out,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
        }
        // Current Claude models can't turn thinking off, so Off is their lowest effort.
        // Claude 5-family models always think; ask for readable summaries so the app can show progress.
        if model.range(of: #"^claude-(opus|sonnet|haiku|fable|mythos)-5"#, options: .regularExpression) != nil {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if let e = options.effort, model.hasPrefix("claude") {
            body["output_config"] = ["effort": e == .off ? "low" : e.rawValue]
        }
        if options.fast, provider == .anthropic { body["speed"] = "fast" }
        return body
    }

    static func chatBody(model: String, provider: ProviderID, system: String, messages: [Message], tools: [ToolSpec],
                         options: RequestOptions = .init()) -> [String: Any] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user:
                if let images = m.images, !images.isEmpty {
                    out.append(["role": "user", "content": [["type": "text", "text": m.textWithDocuments]] + images.map {
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
                    }])
                } else {
                    out.append(["role": "user", "content": m.textWithDocuments])
                }
            case .assistant:
                var a: [String: Any] = ["role": "assistant", "content": m.text.isEmpty ? NSNull() : m.text]
                if !m.toolCalls.isEmpty {
                    a["tool_calls"] = m.toolCalls.map { c -> [String: Any] in
                        var d: [String: Any] = ["id": c.id, "type": "function",
                                                "function": ["name": c.name, "arguments": c.arguments.isEmpty ? "{}" : c.arguments]]
                        if m.provider == provider, let e = c.extra, let extra = (try? JSONSerialization.jsonObject(with: e)) as? [String: Any] {
                            d.merge(extra) { cur, _ in cur }
                        }
                        return d
                    }
                }
                // Thinking models behind OpenCode (DeepSeek, Kimi) require their reasoning echoed back.
                if provider == .opencode, m.provider == provider, let r = m.reasoning, !r.isEmpty { a["reasoning_content"] = r }
                out.append(a)
            case .tool:
                out.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.text])
            }
        }
        var body: [String: Any] = ["model": model, "stream": true, "messages": out]
        // OpenCode proxies strict providers (e.g. Mistral) that reject unknown fields, so it's left out.
        if provider != .opencode { body["stream_options"] = ["include_usage": true] }
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                let schema = provider == .gemini ? geminiSafe(t.schema) : t.schema
                return ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": schema]]
            }
        }
        if let e = options.effort {
            switch provider {
            case .openrouter:
                body["reasoning"] = e == .off ? ["enabled": false] : ["effort": e == .max ? "high" : e.rawValue]
            case .openai:
                body["reasoning_effort"] = e == .off ? "none" : e == .max ? "xhigh" : e.rawValue
            case .gemini, .opencode:
                body["reasoning_effort"] = e == .off ? "none" : e == .max ? "high" : e.rawValue
            case .anthropic, .chatgpt: break
            }
        }
        if options.fast {
            if provider == .openai { body["service_tier"] = "priority" }
            if provider == .openrouter { body["provider"] = ["sort": "throughput"] }
        }
        return body
    }

    static func responsesBody(model: String, provider: ProviderID, system: String, messages: [Message], tools: [ToolSpec],
                              options: RequestOptions = .init()) -> [String: Any] {
        var input: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .user:
                if let images = m.images, !images.isEmpty {
                    input.append(["role": "user", "content": [["type": "input_text", "text": m.textWithDocuments]] + images.map {
                        ["type": "input_image", "image_url": "data:image/jpeg;base64," + $0.base64EncodedString()]
                    }])
                } else {
                    input.append(["role": "user", "content": m.textWithDocuments])
                }
            case .assistant:
                if m.provider == provider, let raw = m.raw,
                   let items = (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] {
                    input += items
                    continue
                }
                if !m.text.isEmpty { input.append(["role": "assistant", "content": m.text]) }
                for c in m.toolCalls {
                    input.append(["type": "function_call", "call_id": c.id, "name": c.name, "arguments": c.arguments.isEmpty ? "{}" : c.arguments])
                }
            case .tool:
                input.append(["type": "function_call_output", "call_id": m.toolCallId ?? "", "output": m.text])
            }
        }
        // This route requires store: false and stream: true, and rejects system items (instructions instead).
        var body: [String: Any] = ["model": model, "instructions": system, "input": input, "store": false, "stream": true,
                                   "include": ["reasoning.encrypted_content"]]
        if !tools.isEmpty {
            // Function tools must be grouped in a namespace on this route.
            body["tools"] = [[
                "type": "namespace", "name": ResponsesParser.namespace,
                "description": "Notestrand app tools: question cards, lesson plans, practice problems and the learner's Obsidian vault.",
                "tools": tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema] },
            ]]
        }
        var reasoning: [String: Any] = ["summary": "auto"] // streamed reasoning summaries for the thinking indicator
        if let e = options.effort { reasoning["effort"] = e == .off ? "none" : e == .max ? "xhigh" : e.rawValue }
        body["reasoning"] = reasoning
        return body
    }

    /// Gemini rejects JSON Schema type arrays like ["string","null"]; keep the non-null type.
    static func geminiSafe(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            if let types = d["type"] as? [String] {
                d["type"] = types.first { $0 != "null" } ?? "string"
                d["nullable"] = true
                if let e = d["enum"] as? [Any] { d["enum"] = e.filter { !($0 is NSNull) } }
            }
            for (k, sub) in d where k != "enum" { d[k] = geminiSafe(sub) }
            return d
        }
        if let a = v as? [Any] { return a.map(geminiSafe) }
        return v
    }

    // MARK: streaming

    /// Streams one reply. `onUpdate` receives the accumulated text, throttled.
    static func stream(model: ModelRef, system: String, messages: [Message], tools: [ToolSpec],
                       options: RequestOptions = .init(), onUpdate: @escaping @MainActor (_ text: String, _ reasoning: String) -> Void) async throws -> Message {
        var options = options
        options.fast = options.fast && RequestOptions.fastSupported(model)
        let path = model.wire == .messages ? "/messages" : model.wire == .responses ? "/responses" : "/chat/completions"
        let body: [String: Any]
        switch model.wire {
        case .messages: body = messagesBody(model: model.id, system: system, messages: messages, tools: tools, provider: model.provider, options: options)
        case .chat: body = chatBody(model: model.id, provider: model.provider, system: system, messages: messages, tools: tools, options: options)
        case .responses: body = responsesBody(model: model.id, provider: model.provider, system: system, messages: messages, tools: tools, options: options)
        }
        let payload = try JSONSerialization.data(withJSONObject: body)

        var stream: URLSession.AsyncBytes?
        for attempt in 0..<2 {
            guard let key = try await credential(for: model.provider), !key.isEmpty else { throw LLMError.noKey(model.provider) }
            var req = URLRequest(url: URL(string: model.provider.baseURL(model.wire) + path)!)
            req.httpMethod = "POST"
            req.timeoutInterval = 600
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authorize(&req, provider: model.provider, wire: model.wire, key: key)
            if options.fast, model.provider == .anthropic { req.setValue("fast-mode-2026-02-01", forHTTPHeaderField: "anthropic-beta") }
            req.httpBody = payload

            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
            // A ChatGPT access token can be revoked early; refresh once and retry.
            if status == 401, model.provider == .chatgpt, attempt == 0 {
                _ = try await ChatGPTAuth.shared.refresh()
                continue
            }
            if status != 200 {
                var data = Data()
                for try await b in bytes { data.append(b); if data.count > 4000 { break } }
                throw LLMError.http(status, errorMessage(data))
            }
            stream = bytes
            break
        }
        guard let bytes = stream else { throw LLMError.http(401, "ChatGPT rejected the sign-in. Sign in again in Settings.") }
        var parser: StreamParser
        switch model.wire {
        case .messages: parser = AnthropicParser()
        case .chat: parser = OpenAIParser()
        case .responses: parser = ResponsesParser()
        }
        var lastPush = Date.distantPast
        var firstToken: Date?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            parser.feed(line)
            if firstToken == nil, !parser.text.isEmpty || !parser.reasoning.isEmpty || !parser.toolCalls.isEmpty { firstToken = Date() }
            if let e = parser.error { throw LLMError.stream(e) }
            if Date().timeIntervalSince(lastPush) > 0.08 {
                lastPush = Date()
                await onUpdate(parser.text, parser.reasoning) // UI work: must run on the main thread
            }
        }
        await onUpdate(parser.text, parser.reasoning)
        guard parser.finished else { throw LLMError.stream("The reply stopped before it finished. Tap Retry.") }
        var reply = Message(role: .assistant, text: parser.text, toolCalls: parser.toolCalls,
                            reasoning: parser.reasoning.isEmpty ? nil : parser.reasoning,
                            usage: parser.usage, provider: model.provider, raw: parser.raw)
        reply.speed = speed(of: reply, since: firstToken)
        return reply
    }

    /// Output tokens per second from the first streamed token to the end. Uses the provider's count when it
    /// reports one, else about 4 characters per token. nil for replies too short to time.
    static func speed(of m: Message, since start: Date?, now: Date = Date()) -> Double? {
        guard let start, now.timeIntervalSince(start) >= 0.3 else { return nil }
        let chars = m.text.count + (m.reasoning?.count ?? 0) + m.toolCalls.reduce(0) { $0 + $1.arguments.count }
        let tokens = m.usage.map(\.output).flatMap { $0 > 0 ? $0 : nil } ?? chars / 4
        return tokens > 0 ? Double(tokens) / now.timeIntervalSince(start) : nil
    }

    /// One non-streamed-looking call that just returns the text (used for knowledge extraction).
    static func complete(model: ModelRef, system: String, prompt: String) async throws -> String {
        try await stream(model: model, system: system, messages: [Message(role: .user, text: prompt)], tools: [], onUpdate: { _, _ in }).text
    }

    static func errorMessage(_ data: Data) -> String {
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let e = o["error"] as? [String: Any], let m = e["message"] as? String {
                // OpenRouter wraps the upstream provider's reason here.
                if let raw = (e["metadata"] as? [String: Any])?["raw"] as? String { return "\(m): \(raw.prefix(300))" }
                return m
            }
            if let arr = o["error"] as? String { return arr }
        }
        if let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let m = (a.first?["error"] as? [String: Any])?["message"] as? String { return m }
        return String(data: data.prefix(500), encoding: .utf8) ?? ""
    }
}
