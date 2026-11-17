import SwiftUI
import Foundation
import XCTest
@testable import Notestrand

final class CoreTests: XCTestCase {
    private var model: ModelRef {
        ModelRef(provider: .anthropic, id: "m", wire: .messages)
    }

    private func makeCall(name: String, id: String, args: [String: Any]) throws -> ToolCall {
        let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return ToolCall(id: id, name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    private func temporaryVault() throws -> (URL, Vault) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notestrand-CoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, Vault(root: root))
    }

    func testAnthropicParserAccumulatesTextAndSplitToolArguments() throws {
        var parser = AnthropicParser()
        [
            "event: message_start",
            "",
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Found "}}"#,
            "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"the note."}}"#,
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"vault_search","input":{}}}"#,
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"trans"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"mission to "}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"LHR\"}"}}"#,
            "event: content_block_stop",
            #"data: {"type":"content_block_stop","index":1}"#,
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].forEach { parser.feed($0) }

        XCTAssertEqual(parser.text, "Found the note.")
        XCTAssertEqual(parser.toolCalls.count, 1)
        XCTAssertEqual(parser.toolCalls[0].id, "toolu_1")
        XCTAssertEqual(parser.toolCalls[0].name, "vault_search")
        XCTAssertEqual(parser.toolCalls[0].args["query"] as? String, "transmission to LHR")
    }

    func testAnthropicParserReportsErrorEvent() {
        var parser = AnthropicParser()
        parser.feed("event: error")
        parser.feed(#"data: {"type":"error","error":{"type":"api_error","message":"boom"}}"#)
        XCTAssertEqual(parser.error, "boom")
    }

    func testOpenAIParserAccumulatesTextSplitToolArgumentsAndExtraContent() throws {
        var parser = OpenAIParser()
        parser.feed(#"data: {"choices":[{"delta":{"content":"Planning "}}]}"#)
        parser.feed(#"data: {"choices":[{"delta":{"content":"a route."}}]}"#)
        parser.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"plan_init","arguments":""},"extra_content":{"google":{"thought_signature":"abc"}}}]}}]}"#)
        parser.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"mer"}}]}}]}"#)
        parser.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"maid\":\"graph TD\"}"}}]}}]}"#)
        parser.feed("data: [DONE]")

        XCTAssertEqual(parser.text, "Planning a route.")
        XCTAssertEqual(parser.toolCalls.count, 1)
        XCTAssertEqual(parser.toolCalls[0].args["mermaid"] as? String, "graph TD")
        let extraData = try XCTUnwrap(parser.toolCalls[0].extra)
        let extra = try XCTUnwrap(try JSONSerialization.jsonObject(with: extraData) as? [String: Any])
        let extraContent = try XCTUnwrap(extra["extra_content"] as? [String: Any])
        let google = try XCTUnwrap(extraContent["google"] as? [String: Any])
        XCTAssertEqual(google["thought_signature"] as? String, "abc")
    }

    func testOpenAIParserAccumulatesReasoningContent() {
        var parser = OpenAIParser()
        parser.feed(#"data: {"choices":[{"delta":{"reasoning_content":"Check "}}]}"#)
        parser.feed(#"data: {"choices":[{"delta":{"reasoning_content":"the steps."}}]}"#)
        XCTAssertEqual(parser.reasoning, "Check the steps.")
    }

    func testOpenAIParserReportsError() {
        var parser = OpenAIParser()
        parser.feed(#"data: {"error":{"message":"boom"}}"#)
        XCTAssertEqual(parser.error, "boom")
    }

    func testMessagesBodyMergesToolResultsAndCachesLastBlocks() throws {
        let tool1 = try makeCall(name: "vault_search", id: "call_1", args: ["query": "one"])
        let tool2 = try makeCall(name: "vault_read", id: "call_2", args: ["path": "Memory.md"])
        let spec = ToolSpec(name: "vault_search", description: "Search notes", schema: ["type": "object"])
        let body = LLMClient.messagesBody(
            model: "m",
            system: "system prompt",
            messages: [
                Message(role: .user, text: "start"),
                Message(role: .assistant, toolCalls: [tool1, tool2]),
                Message(role: .tool, text: "first result", toolCallId: "call_1", toolName: "vault_search"),
                Message(role: .tool, text: "second result", toolCallId: "call_2", toolName: "vault_read", isError: true),
                Message(role: .user, text: "continue"),
            ],
            tools: [spec]
        )

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        let finalBlocks = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(finalBlocks.count, 3)
        XCTAssertEqual(finalBlocks[0]["type"] as? String, "tool_result")
        XCTAssertEqual(finalBlocks[0]["tool_use_id"] as? String, "call_1")
        XCTAssertEqual(finalBlocks[1]["type"] as? String, "tool_result")
        XCTAssertEqual(finalBlocks[1]["tool_use_id"] as? String, "call_2")
        XCTAssertEqual(finalBlocks[1]["is_error"] as? Bool, true)
        XCTAssertEqual(finalBlocks[2]["text"] as? String, "continue")
        XCTAssertNotNil(finalBlocks.last?["cache_control"])

        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertNotNil(system.first?["cache_control"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["input_schema"] as? [String: String], ["type": "object"])
    }

    func testChatBodySerializesToolExtrasAndOpenCodeReasoning() throws {
        let extra = try JSONSerialization.data(withJSONObject: ["extra_content": ["google": ["thought_signature": "abc"]]])
        let call = ToolCall(id: "call_1", name: "plan_init", arguments: "{}", extra: extra)
        let messages = [
            Message(role: .assistant, toolCalls: [call], reasoning: "hidden thought", provider: .opencode),
            Message(role: .tool, text: "done", toolCallId: "call_1", toolName: "plan_init"),
        ]

        let openCodeBody = LLMClient.chatBody(model: "m", provider: .opencode, system: "sys", messages: messages, tools: [])
        let openCodeMessages = try XCTUnwrap(openCodeBody["messages"] as? [[String: Any]])
        XCTAssertEqual(openCodeMessages.first?["role"] as? String, "system")
        let assistant = openCodeMessages[1]
        XCTAssertEqual(assistant["reasoning_content"] as? String, "hidden thought")
        let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertNotNil(toolCalls[0]["extra_content"])
        let toolMessage = openCodeMessages[2]
        XCTAssertEqual(toolMessage["tool_call_id"] as? String, "call_1")

        let openAIBody = LLMClient.chatBody(model: "m", provider: .openai, system: "sys", messages: messages, tools: [])
        let openAIMessages = try XCTUnwrap(openAIBody["messages"] as? [[String: Any]])
        XCTAssertNil(openAIMessages[1]["reasoning_content"])
        // Another provider's extras would be rejected, so switching models mid-session drops them.
        let openAICalls = try XCTUnwrap(openAIMessages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertNil(openAICalls[0]["extra_content"])
    }

    func testCatalogGroupsNamesAndOrdersModels() throws {
        let or = try XCTUnwrap(ModelCatalog.entry(.openrouter, .chat, ["id": "anthropic/claude-opus-5-5", "name": "Anthropic: Claude Opus 5.5", "created": 1_790_000_000.0, "context_length": 1_000_000]))
        XCTAssertEqual(or.group, "Anthropic")
        XCTAssertEqual(or.ref.name, "Claude Opus 5.5")
        XCTAssertEqual(or.ref.contextWindow, 1_000_000)

        let old = try XCTUnwrap(ModelCatalog.entry(.anthropic, .messages, ["id": "claude-opus-4-6", "display_name": "Claude Opus 4.6", "created_at": "2026-02-01T00:00:00Z", "max_input_tokens": 1_000_000]))
        let new = try XCTUnwrap(ModelCatalog.entry(.anthropic, .messages, ["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "created_at": "2026-09-01T00:00:00Z"]))
        let haiku = try XCTUnwrap(ModelCatalog.entry(.anthropic, .messages, ["id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5", "created_at": "2025-10-01T00:00:00Z"]))
        XCTAssertEqual(new.group, "Opus")
        let sections = ModelCatalog.sections([haiku, old, new])
        XCTAssertEqual(sections.map(\.group), ["Opus", "Haiku"])
        XCTAssertEqual(sections[0].models.map(\.id), ["claude-opus-5-5", "claude-opus-4-6"])

        XCTAssertNil(ModelCatalog.entry(.openai, .chat, ["id": "text-embedding-3-large"]))
        XCTAssertEqual(ModelCatalog.entry(.openai, .chat, ["id": "gpt-5.4-mini"])?.group, "GPT-5")
        XCTAssertEqual(ModelCatalog.short(1_000_000), "1M")
        XCTAssertEqual(ModelCatalog.short(200_000), "200K")
        XCTAssertEqual(ModelCatalog.short(162_700), "162.7K")
    }

    func testContextBreakdownUsesReportedUsage() {
        var s = Session(kind: .chat, model: ModelRef(provider: .anthropic, id: "claude-opus-5-5", wire: .messages, contextWindow: 1_000_000))
        s.messages = [Message(role: .user, text: "hi"), Message(role: .assistant, text: "hello", usage: Usage(input: 9_000, output: 1_000))]
        let b = ContextEstimate.breakdown(s, role: .chat, memory: nil)
        XCTAssertTrue(b.measured)
        XCTAssertEqual(b.used, 10_000)
        XCTAssertEqual(b.parts.reduce(0) { $0 + $1.tokens }, b.used)
        XCTAssertEqual(b.free, 990_000)
        XCTAssertEqual(ContextEstimate.window(for: ModelRef(provider: .anthropic, id: "claude-haiku-4-5", wire: .messages)), 200_000)
        XCTAssertEqual(ContextEstimate.window(for: ModelRef(provider: .chatgpt, id: "gpt-5.5", wire: .responses)), 272_000)
    }

    func testClaudeThinkingBlocksReplayUnchanged() throws {
        var p = AnthropicParser()
        for line in [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me look."}}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"vault_search","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"x\"}"}}"#,
        ] { p.feed(line) }
        let reply = Message(role: .assistant, text: p.text, toolCalls: p.toolCalls, provider: .anthropic, raw: p.raw)
        let messages = [Message(role: .user, text: "hi"), reply, Message(role: .tool, text: "none", toolCallId: "toolu_1", toolName: "vault_search")]

        let same = LLMClient.messagesBody(model: "claude-opus-5-5", system: "s", messages: messages, tools: [], provider: .anthropic)
        let assistant = try XCTUnwrap((same["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(assistant[0]["signature"] as? String, "SIG")
        XCTAssertEqual((assistant[2]["input"] as? [String: Any])?["query"] as? String, "x")

        // Another provider never saw those signatures: rebuild from text and tool calls.
        let other = LLMClient.messagesBody(model: "claude-opus-5-5", system: "s", messages: messages, tools: [], provider: .opencode)
        let rebuilt = try XCTUnwrap((other["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        XCTAssertEqual(rebuilt.map { $0["type"] as? String }, ["text", "tool_use"])
    }

    func testEffortAndFastMapPerProvider() {
        let opts = RequestOptions(effort: .off, fast: true)
        let claude = LLMClient.messagesBody(model: "claude-opus-5-5", system: "s", messages: [], tools: [], provider: .anthropic, options: opts)
        XCTAssertEqual((claude["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(claude["speed"] as? String, "fast")

        let openai = LLMClient.chatBody(model: "gpt-5.5", provider: .openai, system: "s", messages: [], tools: [], options: RequestOptions(effort: .max, fast: true))
        XCTAssertEqual(openai["reasoning_effort"] as? String, "xhigh")
        XCTAssertEqual(openai["service_tier"] as? String, "priority")

        let router = LLMClient.chatBody(model: "x", provider: .openrouter, system: "s", messages: [], tools: [], options: opts)
        XCTAssertEqual((router["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)

        XCTAssertNil(LLMClient.chatBody(model: "x", provider: .gemini, system: "s", messages: [], tools: [])["reasoning_effort"])
        XCTAssertTrue(RequestOptions.fastSupported(ModelRef(provider: .anthropic, id: "claude-opus-5-5", wire: .messages)))
        XCTAssertFalse(RequestOptions.fastSupported(ModelRef(provider: .anthropic, id: "claude-sonnet-5-5", wire: .messages)))
    }

    func testParsersReportUsage() {
        var a = AnthropicParser()
        a.feed(#"data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":1}}}"#)
        a.feed(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#)
        XCTAssertEqual(a.usage, Usage(input: 3210, output: 42))

        var o = OpenAIParser()
        o.feed(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#)
        o.feed(#"data: {"choices":[],"usage":{"prompt_tokens":1234,"completion_tokens":56}}"#)
        XCTAssertEqual(o.usage, Usage(input: 1234, output: 56))
        XCTAssertEqual(o.text, "hi")
    }

    func testGeminiSafeRemovesNullTypeAndEnumEntries() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "rung": ["type": ["string", "null"], "enum": ["R0", NSNull()]],
            ],
        ]
        let safe = try XCTUnwrap(LLMClient.geminiSafe(schema) as? [String: Any])
        let properties = try XCTUnwrap(safe["properties"] as? [String: Any])
        let rung = try XCTUnwrap(properties["rung"] as? [String: Any])
        XCTAssertEqual(rung["type"] as? String, "string")
        XCTAssertEqual(rung["nullable"] as? Bool, true)
        XCTAssertEqual(rung["enum"] as? [String], ["R0"])
    }

    func testPlanNodeParsingAndValidation() {
        let mermaid = """
        graph TD
          primitives[Number primitives] --> operators[Arithmetic operators] --> expressions[Evaluating expressions]
          extra-node[Has (parens) and -- dashes]
          operators --> extra-node
        """
        XCTAssertEqual(Tools.planNodes(mermaid), ["primitives", "operators", "expressions", "extra-node"])
        // Ids that start with a Mermaid keyword are still nodes; keyword statements and subgraphs add none.
        let keywordish = """
        flowchart LR
          graph-basics[Graph basics] --> classes[Classes]
          subgraph core [Core ideas]
            style-rules[Style rules]
          end
          classDef done fill:#9f9
          class graph-basics done
        """
        XCTAssertEqual(Tools.planNodes(keywordish), ["graph-basics", "classes", "style-rules"])
        XCTAssertFalse(Tools.planProblems(["Bad Id"]).isEmpty)
        XCTAssertTrue(Tools.planProblems(["ok-id"]).isEmpty)
    }

    func testQuestionProblemsValidateNodeLabelsAndEncodedOptions() throws {
        let options: [[String: String]] = [["label": "Yes", "value": "y"], ["label": "No", "value": "n"]]
        let invalidNode = try makeCall(name: "quiz", id: "q1", args: [
            "question": "Will it work?", "type": "check", "nodeId": "x",
            "options": options, "correctAnswer": "y",
        ])
        XCTAssertTrue(Tools.problems(invalidNode, planNodes: ["a", "b"]).contains { $0.contains("nodeId") && $0.contains("x") })

        let labelAnswer = try makeCall(name: "quiz", id: "q2", args: [
            "question": "Will it work?", "type": "check", "nodeId": "a",
            "options": options, "correctAnswer": "Yes",
        ])
        XCTAssertTrue(Tools.problems(labelAnswer, planNodes: ["a"]).isEmpty)

        let encodedOptions = #"[{"label":"Yes","value":"y"},{"label":"No","value":"n"}]"#
        let encodedProbe = try makeCall(name: "probe", id: "p1", args: [
            "question": "Which answer?", "options": encodedOptions, "correctAnswer": "y",
        ])
        XCTAssertTrue(Tools.problems(encodedProbe, planNodes: []).isEmpty)

        let multiAnswer = try makeCall(name: "quiz", id: "q3", args: [
            "question": "Which answers?", "type": "check", "nodeId": "a",
            "options": options, "correctAnswer": ["y", "n"],
        ])
        XCTAssertTrue(Tools.problems(multiAnswer, planNodes: ["a"]).contains { $0.contains("multiSelect") })
    }

    func testVaultConfinementAppendReadAndSearch() throws {
        let (root, vault) = try temporaryVault()
        XCTAssertEqual(try vault.appURL("Memory.md").lastPathComponent, "Memory.md")
        XCTAssertEqual(try vault.appURL("Notes/a.md").lastPathComponent, "a.md")
        for path in ["../x.md", "/abs.md", "a/../../x.md", "x.txt"] {
            XCTAssertThrowsError(try vault.appURL(path), path)
        }

        let appDirectory = root.appendingPathComponent(Vault.appFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notestrand-Outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: appDirectory.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try vault.appURL("link/evil.md"))

        try vault.write("Notes/a.md", content: "hi", append: false)
        try vault.write("Notes/a.md", content: "there", append: true)
        XCTAssertEqual(try String(contentsOf: appDirectory.appendingPathComponent("Notes/a.md"), encoding: .utf8), "hi\nthere")
        XCTAssertEqual(try vault.readNote("Notestrand/Notes/a.md"), "hi\nthere")
        XCTAssertTrue(try vault.search("there").contains("Notestrand/Notes/a.md"))
        // Reads are notes only: no plugin settings, no hidden folders, no symlinks out of the vault.
        XCTAssertThrowsError(try vault.readNote(".obsidian/plugins/sync/data.json"))
        XCTAssertThrowsError(try vault.readNote(".obsidian/secret.md"))
        try "secret".write(to: outside.appendingPathComponent("evil.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try vault.readNote("Notestrand/link/evil.md"))
    }

    func testKnowledgeParsesSavesAndListsNotes() throws {
        let fenced = """
        The extracted notes are below:
        ```json
        {"title":"Fractions","goal":"Compare fractions","propositions":[{"name":"Common denominator","statement":"Equivalent fractions can share a denominator."},{"name":"Compare numerators","statement":"With equal denominators, compare the numerators."}]}
        ```
        """
        let parsed = try XCTUnwrap(Knowledge.parse(fenced))
        XCTAssertEqual(parsed.title, "Fractions")
        XCTAssertEqual(parsed.props.count, 2)
        XCTAssertFalse(Knowledge.fileName("a/b:c?").contains(where: "/:?".contains))

        let (root, vault) = try temporaryVault()
        let date = ISO8601DateFormatter().date(from: "2026-03-04T12:00:00Z")!
        let noteName = try Knowledge.save(title: parsed.title, goal: parsed.goal, props: parsed.props, date: date, vault: vault)
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        let sessionPath = root.appendingPathComponent("Notestrand/Sessions/\(day) \(parsed.title).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath.path))
        XCTAssertEqual(noteName, "\(day) \(parsed.title)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notestrand/Knowledge/Common denominator.md").path))
        XCTAssertTrue(Knowledge.listSessions(vault: vault).contains(noteName))
        let propositions = try XCTUnwrap(Knowledge.listPropositions(session: noteName, vault: vault))
        XCTAssertTrue(propositions.contains("Equivalent fractions can share a denominator."))
        XCTAssertTrue(propositions.contains("With equal denominators, compare the numerators."))
    }

    func testSessionTracksProbePracticePendingCallsAndSuccessfulPlans() throws {
        let probeDone = try makeCall(name: "probe_done", id: "probe_1", args: [:])
        let successfulTeach = Session(kind: .teach, model: model, messages: [
            Message(role: .assistant, toolCalls: [probeDone]),
            Message(role: .tool, text: "done", toolCallId: "probe_1", toolName: "probe_done"),
        ])
        XCTAssertTrue(successfulTeach.probeDone)
        var failedTeach = successfulTeach
        failedTeach.messages[1].isError = true
        XCTAssertFalse(failedTeach.probeDone)

        let pending1 = try makeCall(name: "quiz", id: "pending_1", args: [:])
        let pending2 = try makeCall(name: "probe", id: "pending_2", args: [:])
        let pendingSession = Session(kind: .teach, model: model, messages: [
            Message(role: .assistant, toolCalls: [pending1, pending2]),
            Message(role: .tool, text: "answered", toolCallId: "pending_1", toolName: "quiz"),
        ])
        XCTAssertEqual(pendingSession.pendingCalls.map(\.id), ["pending_2"])

        let problem = try makeCall(name: "problem", id: "problem_1", args: ["statement": "Compute 2 + 2", "modelSolution": "4"])
        let conclude = try makeCall(name: "conclude", id: "conclude_1", args: [:])
        var practice = Session(kind: .practice, model: model, messages: [
            Message(role: .assistant, toolCalls: [problem]),
            Message(role: .tool, text: "posed", toolCallId: "problem_1", toolName: "problem"),
        ])
        XCTAssertEqual(practice.activeProblem?.id, "problem_1")
        practice.messages.append(Message(role: .assistant, toolCalls: [conclude]))
        practice.messages.append(Message(role: .tool, text: "concluded", toolCallId: "conclude_1", toolName: "conclude"))
        XCTAssertNil(practice.activeProblem)

        let plan1 = try makeCall(name: "plan_init", id: "plan_1", args: ["mermaid": "graph TD\nA[First]"])
        let plan2 = try makeCall(name: "plan_init", id: "plan_2", args: ["mermaid": "graph TD\nB[Second]"])
        let plan3 = try makeCall(name: "plan_init", id: "plan_3", args: ["mermaid": "graph TD\nC[Failed]"])
        let planned = Session(kind: .teach, model: model, messages: [
            Message(role: .assistant, toolCalls: [plan1]),
            Message(role: .tool, text: "ok", toolCallId: "plan_1", toolName: "plan_init"),
            Message(role: .assistant, toolCalls: [plan2]),
            Message(role: .tool, text: "ok", toolCallId: "plan_2", toolName: "plan_init"),
            Message(role: .assistant, toolCalls: [plan3]),
            Message(role: .tool, text: "invalid", toolCallId: "plan_3", toolName: "plan_init", isError: true),
        ])
        XCTAssertEqual(planned.plan, "graph TD\nB[Second]")
    }

    func testPromptsOrderFragmentsAndChatToolSet() throws {
        let bundle = Bundle.main
        let resources = try XCTUnwrap(bundle.resourceURL)
        let probeDoctrine = try String(contentsOf: resources.appendingPathComponent("prompts/prober/10-probe-doctrine.md"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = try String(contentsOf: resources.appendingPathComponent("prompts/shared/10-voice.md"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let questionTools = try String(contentsOf: resources.appendingPathComponent("prompts/shared/20-question-tools.md"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prober = Prompts.system(for: .prober, memory: "remember X")
        XCTAssertTrue(prober.hasPrefix("# The agent"))
        XCTAssertTrue(prober.contains(probeDoctrine))
        XCTAssertTrue(prober.contains(voice))
        XCTAssertLessThan(try XCTUnwrap(prober.range(of: probeDoctrine)?.lowerBound), try XCTUnwrap(prober.range(of: voice)?.lowerBound))
        XCTAssertTrue(prober.hasSuffix("## Notestrand/Memory.md\n\n\(Prompts.memoryNote)\n\nremember X"))

        let practice = Prompts.system(for: .practice, memory: "remember X")
        // Practice has its own base (also titled "# The agent"), never the teaching base.
        let teachingBase = try String(contentsOf: resources.appendingPathComponent("prompts/system-prompt.md"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(practice.contains(teachingBase))
        XCTAssertFalse(practice.contains(questionTools))
        XCTAssertEqual(Tools.specs(for: .chat).map(\.name), ["vault_search", "vault_read", "vault_write", "web_search", "web_fetch"])
    }
}

final class ChatGPTPlanTests: XCTestCase {
    func testReynardLinkKeepsTheWholeSignInURL() throws {
        let page = URL(string: "https://auth.openai.com/api/accounts/authorize?client_id=a&scope=openid email&redirect_uri=http://127.0.0.1:1234/auth/callback")!
        let link = ChatGPTAuth.reynardURL(page)
        XCTAssertEqual(link.scheme, "reynard")
        // Reynard reads the `url` query item; it must come back as the exact page, not cut at the first &.
        let inner = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
        XCTAssertEqual(inner, page.absoluteString)
    }

    func testResponsesParserCollectsTextToolCallsUsageAndReplayItems() throws {
        var p = ResponsesParser()
        for line in [
            #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"ENC"}}"#,
            #"data: {"type":"response.output_text.delta","delta":"Hi "}"#,
            #"data: {"type":"response.output_text.delta","delta":"there"}"#,
            #"data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there"}]}}"#,
            #"data: {"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_1","status":"completed","call_id":"call_9","name":"vault_search","namespace":"notestrand","arguments":"{\"query\":\"x\"}"}}"#,
            #"data: {"type":"response.completed","response":{"usage":{"input_tokens":120,"output_tokens":30},"output":[]}}"#,
        ] { p.feed(line) }
        XCTAssertTrue(p.finished)
        XCTAssertEqual(p.text, "Hi there")
        XCTAssertEqual(p.toolCalls.map(\.id), ["call_9"])
        XCTAssertEqual(p.toolCalls.first?.name, "vault_search")
        XCTAssertEqual(p.usage, Usage(input: 120, output: 30))
        let items = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(p.raw)) as? [[String: Any]])
        XCTAssertEqual(items[0]["encrypted_content"] as? String, "ENC")
        XCTAssertEqual(items[0]["id"] as? String, "rs_1", "reasoning keeps its id with its encrypted content")
        XCTAssertNil(items[1]["id"]); XCTAssertNil(items[2]["status"])
    }

    func testResponsesParserReportsPlanLimitAndUnfinishedStreams() {
        var p = ResponsesParser()
        p.feed(#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"#)
        XCTAssertTrue(p.error?.contains("ChatGPT Settings") == true)
        var q = ResponsesParser()
        q.feed(#"data: {"type":"response.output_text.delta","delta":"partial"}"#)
        XCTAssertFalse(q.finished)
    }

    func testResponsesBodyFollowsPlanRouteRules() throws {
        let call = ToolCall(id: "call_1", name: "vault_read", arguments: #"{"path":"a.md"}"#)
        let messages = [
            Message(role: .user, text: "hi"),
            Message(role: .assistant, text: "Reading.", toolCalls: [call], provider: .anthropic),
            Message(role: .tool, text: "content", toolCallId: "call_1", toolName: "vault_read"),
        ]
        let spec = ToolSpec(name: "vault_read", description: "d", schema: ["type": "object", "properties": [:]])
        let body = LLMClient.responsesBody(model: "gpt-6.1-sol", provider: .chatgpt, system: "SYS", messages: messages, tools: [spec],
                                           options: RequestOptions(effort: .off))
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "SYS")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertFalse(input.contains { $0["role"] as? String == "system" })
        XCTAssertEqual(input.map { ($0["type"] as? String) ?? ($0["role"] as? String) ?? "" }, ["user", "assistant", "function_call", "function_call_output"])
        let ns = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(ns["type"] as? String, "namespace")
        XCTAssertEqual((ns["tools"] as? [[String: Any]])?.first?["name"] as? String, "vault_read")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    }

    func testFreeModelsGetTheirOwnSectionFirst() throws {
        let free = try XCTUnwrap(ModelCatalog.entry(.openrouter, .chat, ["id": "nvidia/nemotron-3-ultra:free", "name": "NVIDIA: Nemotron 3 Ultra (free)", "pricing": ["prompt": "0", "completion": "0"]]))
        let paid = try XCTUnwrap(ModelCatalog.entry(.openrouter, .chat, ["id": "anthropic/claude-opus-5-5", "name": "Anthropic: Claude Opus 5.5", "pricing": ["prompt": "0.000004", "completion": "0.00002"], "created": 1_795_000_000.0]))
        let zen = try XCTUnwrap(ModelCatalog.entry(.opencode, .chat, ["id": "big-pickle", "name": "Big Pickle", "cost": ["input": 0, "output": 0], "api": ["chat-completions": [:]]]))
        XCTAssertEqual(free.group, "Free")
        XCTAssertEqual(paid.group, "Anthropic")
        XCTAssertEqual(zen.group, "Free")
        XCTAssertEqual(ModelCatalog.sections([paid, free]).map(\.group), ["Free", "Anthropic"])
    }

    func testIDTokenClaimsDecode() {
        let payload = Data(#"{"sub":"user-1","aud":"oaiapp_x","iss":"https://auth.openai.com","nonce":"n"}"#.utf8).base64URL
        let claims = ChatGPTAuth.claims("e30.\(payload).sig")
        XCTAssertEqual(claims["sub"] as? String, "user-1")
        XCTAssertEqual(Data(base64URL: Data("hello?".utf8).base64URL), Data("hello?".utf8))
    }

    func testKeyProvidersNeverIncludeTheSignInProvider() {
        // Settings saves every key provider on close; including the plan would erase its sign-in.
        XCTAssertFalse(ProviderID.keyProviders.contains(.chatgpt))
        XCTAssertEqual(ProviderID.keyProviders.count, ProviderID.allCases.count - 1)
    }
}

final class WebToolsTests: XCTestCase {
    func testReadableTextDropsChromeAndKeepsStructure() {
        let html = """
        <html><head><title>Break-even &amp; CVP</title><style>p{color:red}</style></head>
        <body><nav>Home | About</nav><h1>Break-even</h1><p>Fixed costs &pound;4,000.</p>
        <script>alert(1)</script><ul><li>Price</li><li>Variable cost</li></ul><footer>© site</footer></body></html>
        """
        let text = WebTools.readable(html)
        XCTAssertTrue(text.contains("## Break-even"))
        XCTAssertTrue(text.contains("Fixed costs £4,000."))
        XCTAssertTrue(text.contains("- Price"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("Home | About"))
        XCTAssertFalse(text.contains("© site"))
        XCTAssertEqual(WebTools.strip("A &#8364; &#x41;"), "A € A")
    }

    func testPrivateHostsAreRefused() async {
        for host in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.20.0.1", "169.254.1.1", "printer.local"] {
            XCTAssertTrue(WebTools.isPrivate(host), host)
        }
        XCTAssertFalse(WebTools.isPrivate("example.com"))
        XCTAssertFalse(WebTools.isPrivate("8.8.8.8"))
        do { _ = try await WebTools.fetch("file:///etc/passwd"); XCTFail("file URL accepted") } catch {}
        do { _ = try await WebTools.fetch("http://192.168.1.1/admin"); XCTFail("LAN URL accepted") } catch {}
        for host in ["::1", "[::1]", "fe80::1%en0", "fd12::3", "::ffff:192.168.0.1", "100.64.0.1", "0.0.0.0", "router.home.arpa"] {
            XCTAssertTrue(WebTools.isPrivate(host), host)
        }
        XCTAssertFalse(WebTools.isPrivate("2606:4700::1111"))
        // Odd IP spellings resolve to loopback, and the resolved address is what gets checked.
        let loopback = WebTools.resolve("2130706433")
        XCTAssertFalse(loopback.isEmpty)
        XCTAssertTrue(loopback.allSatisfy(WebTools.isPrivate), "\(loopback)")
        do { _ = try await WebTools.fetch("http://0x7f.1/"); XCTFail("hex loopback accepted") } catch {}
    }
}

final class DuckDuckGoTests: XCTestCase {
    func testParsesResultsAndUnwrapsRedirects() {
        let html = """
        <div class="result"><h2><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FBreak-even&amp;rut=abc">Break-even &amp; <b>point</b></a></h2>
        <a class="result__snippet" href="x">The <b>break-even</b> point is where costs equal revenue.</a></div>
        <div class="result"><a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad=1">Ad</a></div>
        """
        let r = WebTools.parseDuckDuckGo(html)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.url, "https://en.wikipedia.org/wiki/Break-even")
        XCTAssertEqual(r.first?.title, "Break-even & point")
        XCTAssertEqual(r.first?.snippet, "The break-even point is where costs equal revenue.")
    }
}

@MainActor
final class MessageActionTests: XCTestCase {
    func testEditLastRemovesOnlyTheLastTypedTurn() throws {
        let app = AppState()
        app.newSession(.chat, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        let id = try XCTUnwrap(app.selected)
        defer { if let s = app.current { app.delete(s) } }
        let i = try XCTUnwrap(app.sessions.firstIndex { $0.id == id })
        app.sessions[i].messages = [
            Message(role: .user, text: "first"), Message(role: .assistant, text: "a1"),
            Message(role: .user, text: "*Your thinking*\n\nsecond"), Message(role: .assistant, text: "a2"),
        ]
        XCTAssertEqual(app.editLast(), "second")
        XCTAssertEqual(app.sessions[i].messages.map(\.text), ["first", "a1"])

        // A card answer after the last typed message: edit must not delete it.
        var answer = Message(role: .tool, text: "{}", toolCallId: "c", toolName: "quiz")
        answer.answer = Data("{}".utf8)
        app.sessions[i].messages.append(answer)
        XCTAssertNil(app.editLast())
        XCTAssertEqual(app.sessions[i].messages.count, 3)
    }
}

@MainActor
final class NewFeatureTests: XCTestCase {
    func testQuickPromptExpansion() {
        QuickPrompt.all = QuickPrompt.defaults
        XCTAssertEqual(QuickPrompt.expand("/explain photosynthesis"), "Explain photosynthesis simply, step by step, with an everyday example.")
        XCTAssertEqual(QuickPrompt.expand("/EXPLAIN"), "Explain this simply, step by step, with an everyday example.")
        XCTAssertNil(QuickPrompt.expand("/btw hi"))
        XCTAssertNil(QuickPrompt.expand("explain x"))
    }

    func testPhotosAndDocumentsReachEveryFormat() throws {
        var m = Message(role: .user, text: "What is this?")
        m.images = [Data([1, 2, 3])]
        m.documents = [Attachment(name: "notes.pdf", text: "Fixed costs are £4000.")]
        XCTAssertTrue(m.textWithDocuments.hasPrefix("<document name=\"notes.pdf\">"))

        let claude = LLMClient.messagesBody(model: "claude-opus-5-5", system: "s", messages: [m], tools: [])
        let blocks = try XCTUnwrap((claude["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["image", "text"])
        XCTAssertEqual((claude["thinking"] as? [String: Any])?["display"] as? String, "summarized")
        XCTAssertNil(LLMClient.messagesBody(model: "claude-haiku-4-5", system: "s", messages: [m], tools: [])["thinking"])

        let chat = LLMClient.chatBody(model: "x", provider: .openrouter, system: "s", messages: [m], tools: [])
        let parts = try XCTUnwrap((chat["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url"])

        let resp = LLMClient.responsesBody(model: "x", provider: .chatgpt, system: "s", messages: [m], tools: [])
        let input = try XCTUnwrap((resp["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, ["input_text", "input_image"])
        XCTAssertEqual((resp["reasoning"] as? [String: Any])?["summary"] as? String, "auto")
    }

    func testBranchCopiesHistoryBeforeTheMessage() throws {
        let app = AppState()
        app.newSession(.chat, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        let original = try XCTUnwrap(app.selected)
        let i = try XCTUnwrap(app.sessions.firstIndex { $0.id == original })
        let first = Message(role: .user, text: "first"), second = Message(role: .user, text: "second")
        app.sessions[i].messages = [first, Message(role: .assistant, text: "a1"), second, Message(role: .assistant, text: "a2")]
        XCTAssertEqual(app.branch(from: second.id), "second")
        let branch = try XCTUnwrap(app.current)
        defer { app.delete(branch); if let o = app.sessions.first(where: { $0.id == original }) { app.delete(o) } }
        XCTAssertNotEqual(branch.id, original)
        XCTAssertEqual(branch.messages.map(\.text), ["first", "a1"])
        XCTAssertEqual(app.sessions.first { $0.id == original }?.messages.count, 4, "original untouched")
    }

    func testOldSessionsStillDecode() throws {
        // A session file written before pins, projects and attachments existed.
        let json = #"{"id":"6E0C3B7E-1111-4222-8333-444455556666","title":"Old","kind":"chat","model":{"provider":"openrouter","id":"x","wire":"chat"},"messages":[{"id":"7E0C3B7E-1111-4222-8333-444455556666","role":"user","text":"hi","toolCalls":[],"isError":false}],"created":800000000,"savedToKnowledge":false}"#
        let s = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(s.pinned); XCTAssertNil(s.projectId); XCTAssertNil(s.messages[0].images)
    }
}

@MainActor
final class SpeedAndOnboardingTests: XCTestCase {
    func testBackgroundSavesLoadBackAndDeletesStick() throws {
        var s = Session(kind: .chat, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        s.title = "cache test \(UUID())"
        s.messages = [Message(role: .user, text: "hello")]
        SessionStore.saveLater(s) { XCTFail("save failed: \($0)") }
        SessionStore.flush()
        XCTAssertEqual(SessionStore.loadAll().first { $0.id == s.id }?.messages.first?.text, "hello")

        // A delete queued behind a save must win, or a deleted chat could come back.
        s.messages.append(Message(role: .assistant, text: "hi"))
        SessionStore.saveLater(s) { _ in }
        SessionStore.delete(s)
        SessionStore.flush()
        XCTAssertNil(SessionStore.loadAll().first { $0.id == s.id })
    }

    func testModelListIsCachedPerProvider() {
        let before = ModelCatalog.cached(.opencode)
        defer { ModelCatalog.remember(before, for: .opencode) }
        let entry = CatalogEntry(ref: ModelRef(provider: .opencode, id: "test-model", wire: .chat, name: "Test", contextWindow: 1000), group: "Free", created: Date(timeIntervalSince1970: 1))
        ModelCatalog.remember([entry], for: .opencode)
        let back = ModelCatalog.cached(.opencode)
        XCTAssertEqual(back.map(\.id), ["test-model"])
        XCTAssertEqual(back.first?.ref.contextWindow, 1000)
        XCTAssertEqual(back.first?.group, "Free")
    }

    func testHomeStatsCountLessonsAndSolvedProblems() {
        var teach = Session(kind: .teach, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        teach.messages = [
            Message(role: .assistant, toolCalls: [ToolCall(id: "p", name: "probe_done", arguments: "{}")]),
            Message(role: .tool, text: "ok", toolCallId: "p", toolName: "probe_done"),
        ]
        var practice = Session(kind: .practice, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        practice.messages = [
            Message(role: .assistant, toolCalls: [ToolCall(id: "c1", name: "conclude", arguments: #"{"outcome":"solved"}"#)]),
            Message(role: .assistant, toolCalls: [ToolCall(id: "c2", name: "conclude", arguments: #"{"outcome":"surrendered"}"#)]),
        ]
        let stats = HomeStats([teach, practice])
        XCTAssertEqual(stats.lessons, 1)
        XCTAssertEqual(stats.solved, 1)
    }

    func testOnlyRefusedKeysCountAsWrong() {
        XCTAssertTrue(OnboardingView.keyRejected(LLMError.http(401, "bad key")))
        XCTAssertFalse(OnboardingView.keyRejected(LLMError.http(503, "down")), "an outage isn't the learner's typo")
        XCTAssertFalse(OnboardingView.keyRejected(URLError(.notConnectedToInternet)))
    }
}

@MainActor
final class VaultAccessTests: XCTestCase {
    func testReadOnlyBlocksEveryWriteAndHidesTheWriteTool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("access-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        let previous = Prefs.d.string(forKey: Prefs.vaultAccess)
        defer { Prefs.d.set(previous, forKey: Prefs.vaultAccess) }

        Prefs.d.set(VaultAccess.readOnly.rawValue, forKey: Prefs.vaultAccess)
        XCTAssertThrowsError(try vault.write("Memory.md", content: "x", append: false))
        XCTAssertNil(vault.appNote("Memory.md"), "nothing reached the disk")
        XCTAssertFalse(Tools.specs(for: .chat).contains { $0.name == "vault_write" })
        XCTAssertTrue(Tools.specs(for: .chat).contains { $0.name == "vault_read" }, "reading still works")
        XCTAssertTrue(Prompts.system(for: .chat, memory: nil).contains("read-only"))

        Prefs.d.set(VaultAccess.readWrite.rawValue, forKey: Prefs.vaultAccess)
        try vault.write("Memory.md", content: "x", append: false)
        XCTAssertEqual(vault.appNote("Memory.md"), "x")
        XCTAssertTrue(Tools.specs(for: .chat).contains { $0.name == "vault_write" })
    }
}

final class CustomAccentTests: XCTestCase {
    func testCustomColourRoundTripsAndDrivesTheCustomAccent() {
        XCTAssertEqual(Color("#0f8b8d").hex, "#0f8b8d")
        let previous = Prefs.d.string(forKey: Prefs.customAccent)
        defer { Prefs.d.set(previous, forKey: Prefs.customAccent) }
        Prefs.d.set("#123abc", forKey: Prefs.customAccent)
        XCTAssertEqual(Accent.custom.hex, "#123abc")
        XCTAssertFalse(Accent.presets.contains(.custom))
    }
}

@MainActor
final class ShareInboxTests: XCTestCase {
    func testSharedItemsArriveOnceAndOrdinaryClipboardIsLeftAlone() throws {
        _ = ShareInbox.takeAll() // start empty
        UIPasteboard.general.string = "something the learner copied"
        try ShareInbox.put(ShareInbox.Item(images: [Data([1, 2, 3])], text: "https://example.com/page"))
        let got = ShareInbox.takeAll()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.text, "https://example.com/page")
        XCTAssertEqual(got.first?.images.first, Data([1, 2, 3]))
        XCTAssertTrue(ShareInbox.takeAll().isEmpty, "each share is delivered once")

        UIPasteboard.general.string = "just a copied link https://example.com"
        XCTAssertTrue(ShareInbox.takeAll().isEmpty, "an ordinary copy is never taken as a share")
    }

    func testSharesGoToTheLastChatsMessageBox() async throws {
        let app = AppState()
        await app.load()
        app.newSession(.chat, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        let chat = try XCTUnwrap(app.selected)
        defer { if let s = app.sessions.first(where: { $0.id == chat }) { app.delete(s) } }
        app.selected = nil // learner went Home
        _ = ShareInbox.takeAll()
        try ShareInbox.put(ShareInbox.Item(text: "https://example.com"))
        app.receiveShared()
        XCTAssertEqual(app.selected, chat, "opens the chat they were last in")
        XCTAssertEqual(app.shared[chat]?.text, "https://example.com")
        XCTAssertTrue(app.sessions.first { $0.id == chat }?.messages.isEmpty == true, "not sent; waits in the message box")
    }
}

@MainActor
final class ExamModeTests: XCTestCase {
    func testExamSessionsUseTheExaminerPromptAndResearchTools() {
        let app = AppState()
        let exam = Session(kind: .exam, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        XCTAssertEqual(app.role(exam), .examiner)
        let prompt = Prompts.base(for: .examiner)
        XCTAssertTrue(prompt.hasPrefix("# The examiner"))
        XCTAssertTrue(prompt.contains("## Mark: X / Y"))
        XCTAssertTrue(prompt.contains("Never present marking points you made up as official"))
        XCTAssertFalse(prompt.contains("# The agent"), "no teaching prompt")
        let tools = Set(Tools.specs(for: .examiner).map(\.name))
        XCTAssertTrue(tools.isSuperset(of: ["vault_search", "vault_read", "web_fetch"]))
        XCTAssertTrue(tools.isDisjoint(with: ["quiz", "problem", "probe", "plan_init"]))
    }
}

final class PersonalisationTests: XCTestCase {
    func testReplySpeedUsesReportedTokensOrEstimates() {
        let start = Date(timeIntervalSince1970: 0)
        var m = Message(role: .assistant, text: String(repeating: "a", count: 400))
        XCTAssertEqual(LLMClient.speed(of: m, since: start, now: start.addingTimeInterval(2)) ?? 0, 50, accuracy: 0.01) // 100 tokens by estimate
        m.usage = Usage(input: 10, output: 300)
        XCTAssertEqual(LLMClient.speed(of: m, since: start, now: start.addingTimeInterval(2)) ?? 0, 150, accuracy: 0.01)
        XCTAssertNil(LLMClient.speed(of: m, since: start, now: start.addingTimeInterval(0.1)))
        XCTAssertNil(LLMClient.speed(of: m, since: nil))
    }

    func testStyleChoicesReachThePrompt() {
        let keys = [Prefs.tutorTone, Prefs.replyLength, Prefs.spelling, Prefs.studyLevel, Prefs.learnerName, Prefs.learnerPronouns, Prefs.customInstructions]
        let saved = keys.map { Prefs.d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { Prefs.d.set(v, forKey: k) } }
        keys.forEach { Prefs.d.removeObject(forKey: $0) }
        XCTAssertNil(Prefs.promptAddition)
        Prefs.d.set("direct", forKey: Prefs.tutorTone)
        Prefs.d.set("short", forKey: Prefs.replyLength)
        Prefs.d.set("british", forKey: Prefs.spelling)
        Prefs.d.set("A-level", forKey: Prefs.studyLevel)
        let p = Prefs.promptAddition ?? ""
        for phrase in ["direct and to the point", "Keep replies short", "British spelling", "level of study: A-level"] { XCTAssertTrue(p.contains(phrase), phrase) }
    }
}

@MainActor
final class UpdaterTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertTrue(Updater.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(Updater.isNewer("0.1.1", than: "0.1"))
        XCTAssertFalse(Updater.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(Updater.isNewer("0.1.0", than: "0.2.0"))
    }

    func testReleaseOnlyTakesThisRepositorysFiles() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/footfungus2/Notestrand/releases/tag/v0.2.0","assets":[
          {"browser_download_url":"https://evil.example/Notestrand.ipa"},
          {"browser_download_url":"https://github.com/footfungus2/Notestrand/releases/download/v0.2.0/Notestrand.ipa"},
          {"browser_download_url":"https://github.com/footfungus2/Notestrand/releases/download/v0.2.0/Notestrand.tipa"}]}
        """
        let r = try Updater.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.ipa?.absoluteString, "https://github.com/footfungus2/Notestrand/releases/download/v0.2.0/Notestrand.ipa")
        XCTAssertEqual(r.tipa?.pathExtension, "tipa")
        // TrollStore reads the url query item; it must be the whole download link.
        let link = appLink("apple-magnifier://install", carrying: r.tipa!)
        XCTAssertEqual(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, r.tipa!.absoluteString)
    }
}

/// Regression tests for the November 2026 security audit.
@MainActor
final class HardeningTests: XCTestCase {
    func testOnlyLinksInTheConversationOpenABrowser() {
        typealias C = Transcript.Coordinator
        let web = URL(string: "https://example.com/?q=1")!
        XCTAssertEqual(C.decide(web, type: .linkActivated, fromMainFrame: true, toMainFrame: true).open, web)
        // A demo clicking its own link from script, or sending itself somewhere, must not leave the app.
        XCTAssertNil(C.decide(web, type: .linkActivated, fromMainFrame: false, toMainFrame: false).open)
        XCTAssertNil(C.decide(web, type: .linkActivated, fromMainFrame: false, toMainFrame: nil).open)
        XCTAssertNil(C.decide(web, type: .other, fromMainFrame: true, toMainFrame: true).open)
        XCTAssertNil(C.decide(URL(string: "apple-magnifier://install?url=x"), type: .linkActivated, fromMainFrame: true, toMainFrame: true).open)
        XCTAssertEqual(C.decide(web, type: .linkActivated, fromMainFrame: true, toMainFrame: true).0, .cancel)
        // The bundled page loads in the main frame only; demo frames only load their own about:srcdoc.
        XCTAssertEqual(C.decide(TranscriptHost.page, type: .other, fromMainFrame: true, toMainFrame: true).0, .allow)
        XCTAssertEqual(C.decide(TranscriptHost.page, type: .linkActivated, fromMainFrame: false, toMainFrame: false).0, .cancel)
        XCTAssertEqual(C.decide(URL(string: "about:srcdoc"), type: .other, fromMainFrame: true, toMainFrame: false).0, .allow)
    }

    func testModelWrittenTextOnlyLinksToWebPages() {
        XCTAssertTrue(isWebLink(URL(string: "https://example.com")!))
        XCTAssertTrue(isWebLink(URL(string: "HTTP://example.com")!))
        for other in ["apple-magnifier://install?url=https://evil.example/a.ipa", "sidestore://install?url=x", "notestrand://shared", "tel:999", "javascript:alert(1)", "file:///etc/passwd"] {
            XCTAssertFalse(isWebLink(URL(string: other)!), other)
        }
    }

    func testToolsTheTurnDidntOfferAreRefused() {
        XCTAssertNil(AppState.refusal(for: "vault_search", offered: ["vault_search"]))
        XCTAssertNotNil(AppState.refusal(for: "web_fetch", offered: ["vault_search"]))
        // With web access off the web tools aren't offered, so naming one anyway doesn't run it.
        let old = Prefs.d.object(forKey: Prefs.webAccess)
        defer { Prefs.d.set(old, forKey: Prefs.webAccess) }
        Prefs.d.set(false, forKey: Prefs.webAccess)
        let offered = Set(Tools.specs(for: .chat).map(\.name))
        XCTAssertNotNil(AppState.refusal(for: "web_fetch", offered: offered))
        XCTAssertNotNil(AppState.refusal(for: "web_search", offered: offered))
    }

    func testVaultSearchSkipsHiddenFoldersAndLinksOutOfTheVault() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
        let root = base.appendingPathComponent("vault"), outside = base.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".plugin-data"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "apple pie recipe".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "apple hidden token".write(to: root.appendingPathComponent(".plugin-data/secret.md"), atomically: true, encoding: .utf8)
        try "apple outside the vault".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside)
        let found = try Vault(root: root).search("apple")
        XCTAssertTrue(found.contains("note.md"))
        XCTAssertFalse(found.contains("hidden token"))
        XCTAssertFalse(found.contains("outside the vault"))
        XCTAssertFalse(found.contains("link.md"))
    }

    func testNotesTheAppWritesCantRunCodeInObsidian() {
        XCTAssertEqual(Vault.inert("```dataviewjs\ndv.x()\n```"), "```js\ndv.x()\n```")
        XCTAssertEqual(Vault.inert("  ~~~~ DataviewJS\nx\n~~~~"), "  ~~~~ js\nx\n~~~~")
        XCTAssertEqual(Vault.inert("> ```js-engine\n> x\n> ```"), "> ```js\n> x\n> ```")
        XCTAssertEqual(Vault.inert("Total: `$= dv.pages().length`"), "Total: `$ = dv.pages().length`")
        // Markdown trims one space from each end of inline code, so a leading space alone wouldn't stop it.
        XCTAssertEqual(Vault.inert("Total: ` $= dv.x() `"), "Total: ` $ = dv.x() `")
        // Fences inside list items run too.
        XCTAssertEqual(Vault.inert("- ```dataviewjs\n  dv.x()\n  ```"), "- ```js\n  dv.x()\n  ```")
        XCTAssertEqual(Vault.inert("1. ~~~meta-bind-js-view\n   x\n   ~~~"), "1. ~~~js\n   x\n   ~~~")
        let plain = "```js\nlet a = 1\n```\n\n```dataview\nTABLE file.name\n```\n\nIt costs `$5`, not $= 5."
        XCTAssertEqual(Vault.inert(plain), plain)
    }

    func testUpdaterRejectsAReleasePageOutsideTheRepository() {
        let json = #"{"tag_name":"v9.0.0","html_url":"https://evil.example/Notestrand/releases","assets":[]}"#
        XCTAssertThrowsError(try Updater.parse(Data(json.utf8)))
    }

    func testAStrayCallbackDoesntPushOutTheRealOne() async throws {
        let callback = try LoopbackCallback()
        callback.finish(.success(["state": "someone-else"]))
        callback.finish(.success(["state": "ours", "code": "abc"]))
        let first = try await callback.result(), second = try await callback.result()
        XCTAssertEqual(first["state"], "someone-else")
        XCTAssertEqual(second["code"], "abc")
    }

    func testHugeTextAttachmentIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(count: PendingAttachments.maxTextBytes + 1).write(to: file)
        XCTAssertThrowsError(try PendingAttachments.document(at: file))
    }
}

/// Serves canned chat-completions streams, one per request, so the turn loop runs without a network.
final class StubLLM: URLProtocol {
    static var replies: [String] = []
    /// Request bodies as sent, oldest first.
    static var bodies: [[String: Any]] = []

    static func call(_ name: String, id: String) -> String {
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"\#(id)","function":{"name":"\#(name)","arguments":"{}"}}]}}]}"# + "\n\ndata: [DONE]\n\n"
    }
    static func text(_ t: String) -> String { #"data: {"choices":[{"delta":{"content":"\#(t)"}}]}"# + "\n\ndata: [DONE]\n\n" }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "openrouter.ai" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // A URLProtocol sees the request body only as a stream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        let body = Self.replies.isEmpty ? "data: [DONE]\n\n" : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class TurnLoopTests: XCTestCase {
    /// A session on a stubbed provider; `done` removes it and puts back the learner's real key.
    private func stubbed(_ kind: SessionKind, replies: [String]) throws -> (app: AppState, id: UUID, done: () -> Void) {
        let saved = KeyStore.get(.openrouter)
        KeyStore.set(.openrouter, "stub-key")
        StubLLM.replies = replies
        StubLLM.bodies = []
        URLProtocol.registerClass(StubLLM.self)
        let app = AppState()
        app.vault = Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("no-vault-\(UUID())"))
        app.newSession(kind, model: ModelRef(provider: .openrouter, id: "stub", wire: .chat))
        let id = try XCTUnwrap(app.selected)
        return (app, id, {
            if let s = app.sessions.first(where: { $0.id == id }) { app.delete(s) }
            URLProtocol.unregisterClass(StubLLM.self)
            KeyStore.set(.openrouter, saved ?? "")
        })
    }

    private func finish(_ app: AppState) async throws {
        let deadline = Date().addingTimeInterval(10)
        while app.running, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(app.running, "turn didn't finish")
    }

    private func toolNames(_ body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    func testProbeHandsOffToTheTeacherAfterItsClosingWords() async throws {
        let t = try stubbed(.teach, replies: [StubLLM.call("probe_done", id: "p1"), StubLLM.text("Thanks, that's all I needed."), StubLLM.text("Here is the plan.")])
        defer { t.done() }
        t.app.send("Teach me derivatives")
        try await finish(t.app)
        XCTAssertNil(t.app.error, t.app.error ?? "")
        let s = try XCTUnwrap(t.app.sessions.first { $0.id == t.id })
        XCTAssertEqual(s.messages.map { $0.toolName ?? $0.role.rawValue }, ["user", "assistant", "probe_done", "assistant", "handoff", "assistant"])
        // The closing words still come from the prober; the plan comes from the teacher.
        XCTAssertEqual(StubLLM.bodies.count, 3)
        XCTAssertTrue(toolNames(StubLLM.bodies[1]).contains("probe_done"))
        XCTAssertTrue(toolNames(StubLLM.bodies[2]).contains("plan_init"))
    }

    func testRetryAfterACutOffReplyAsksAgainWithoutTheHalfReply() async throws {
        let t = try stubbed(.chat, replies: [StubLLM.text("Full answer.")])
        defer { t.done() }
        let i = try XCTUnwrap(t.app.index(t.id))
        // What the loop keeps when a stream breaks off: text only, no provider.
        t.app.sessions[i].messages = [Message(role: .user, text: "Why?"), Message(role: .assistant, text: "Because the")]
        t.app.retry()
        try await finish(t.app)
        XCTAssertEqual(t.app.sessions.first { $0.id == t.id }?.messages.map(\.text), ["Why?", "Full answer."])
        XCTAssertEqual((StubLLM.bodies.first?["messages"] as? [[String: Any]])?.last?["role"] as? String, "user")
    }

    func testEmptyReplyIsntSavedAndOnlyItsTurnOffersRetry() async throws {
        let t = try stubbed(.chat, replies: ["data: [DONE]\n\n"])
        defer { t.done() }
        t.app.send("Hello")
        try await finish(t.app)
        XCTAssertNotNil(t.app.error)
        XCTAssertEqual(t.app.failedTurn, t.id)
        XCTAssertEqual(t.app.sessions.first { $0.id == t.id }?.messages.map(\.role), [.user])
        // Any other error (a failed save, say) has no turn to retry.
        t.app.error = "Couldn't save projects."
        XCTAssertNil(t.app.failedTurn)

        // Empty replies saved before this fix are left out, or chat-format providers reject every later turn.
        let body = LLMClient.chatBody(model: "x", provider: .openai, system: "s",
                                      messages: [Message(role: .user, text: "a"), Message(role: .assistant), Message(role: .user, text: "b")], tools: [])
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.map { $0["role"] as? String }, ["system", "user", "user"])
    }
}
