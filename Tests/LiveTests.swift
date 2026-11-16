import XCTest
@testable import Notestrand

/// Hits a real provider. Skipped unless OPENROUTER_API_KEY reaches the test process:
/// `TEST_RUNNER_OPENROUTER_API_KEY=$OPENROUTER_API_KEY xcodebuild test ...`
@MainActor
final class LiveTests: XCTestCase {
    func testChatTurnRunsVaultToolAgainstOpenRouter() async throws {
        let key = try liveKey()
        let model = liveModel
        let saved = KeyStore.get(.openrouter)
        KeyStore.set(.openrouter, key)
        defer { KeyStore.set(.openrouter, saved ?? "") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Physics"), withIntermediateDirectories: true)
        try "Entropy counts the microstates compatible with a macrostate. My teacher's nickname for it is BLUEFOX."
            .write(to: root.appendingPathComponent("Physics/Entropy.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppState()
        app.vault = Vault(root: root)
        app.newSession(.chat, model: ModelRef(provider: .openrouter, id: model, wire: .chat))
        let id = try XCTUnwrap(app.selected)
        defer { if let s = app.current { app.delete(s) } }

        app.send("Use vault_search to find my note about entropy, then tell me the nickname my teacher uses for it. Reply with just the nickname.")
        let deadline = Date().addingTimeInterval(180)
        while app.running, Date() < deadline { try await Task.sleep(nanoseconds: 300_000_000) }

        XCTAssertNil(app.error, app.error ?? "")
        let s = try XCTUnwrap(app.sessions.first { $0.id == id })
        let calls = s.messages.flatMap(\.toolCalls)
        XCTAssertTrue(calls.contains { $0.name == "vault_search" }, "no vault_search call: \(s.messages.map(\.text))")
        XCTAssertTrue(s.messages.contains { $0.role == .tool && $0.text.contains("Physics/Entropy.md") })
        let answer = s.messages.last { $0.role == .assistant }?.text ?? ""
        XCTAssertTrue(answer.uppercased().contains("BLUEFOX"), "final answer: \(answer)")
    }

    /// The full prober prompt and tool schemas are accepted, and the first turn poses a valid question card.
    func testTeachSessionProberPosesAQuestion() async throws {
        let key = try liveKey()
        let saved = KeyStore.get(.openrouter)
        KeyStore.set(.openrouter, key)
        defer { KeyStore.set(.openrouter, saved ?? "") }

        let app = AppState()
        app.vault = Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID())"))
        app.newSession(.teach, model: ModelRef(provider: .openrouter, id: liveModel, wire: .chat))
        let id = try XCTUnwrap(app.selected)
        defer { if let s = app.current { app.delete(s) } }

        app.send("I want to understand why the derivative of sin(x) is cos(x).")
        let deadline = Date().addingTimeInterval(240)
        while app.running, Date() < deadline { try await Task.sleep(nanoseconds: 300_000_000) }

        XCTAssertNil(app.error, app.error ?? "")
        let s = try XCTUnwrap(app.sessions.first { $0.id == id })
        let pending = s.pendingCalls
        XCTAssertTrue(pending.contains { ["probe", "ask_user_question"].contains($0.name) },
                      "expected an open question card; transcript: \(s.messages.map { "\($0.role): \($0.text.prefix(200)) \($0.toolCalls.map(\.name))" })")
        for c in pending { XCTAssertEqual(Tools.problems(c, planNodes: []), [], c.arguments) }
    }

    private func liveKey() throws -> String {
        guard let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !k.isEmpty else { throw XCTSkip("no OPENROUTER_API_KEY") }
        return k
    }

    private var liveModel: String {
        ProcessInfo.processInfo.environment["LIVE_MODEL"] ?? "nvidia/nemotron-3-ultra-550b-a55b:free"
    }
}
