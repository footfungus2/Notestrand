import PencilKit
import XCTest
@testable import Notestrand

@MainActor
final class StudyFeatureTests: XCTestCase {
    private let quiz = ToolCall(id: "q1", name: "quiz", arguments: #"""
    {"type":"check","nodeId":"n","question":"What is $2+2$?","options":[{"label":"3","value":"a"},{"label":"4","value":"b"}],
     "explanation":"Count on from two.","correctAnswer":"b"}
    """#)

    // MARK: needs work

    func testMissedQuestionsBecomeCards() throws {
        let wrong = try XCTUnwrap(NeedsWork.card(question: quiz, correct: false, dontKnow: false, confidence: 90))
        XCTAssertEqual(wrong.deck, NeedsWork.deck)
        XCTAssertEqual(wrong.front, "What is $2+2$?")
        XCTAssertEqual(wrong.back, "**Answer:** 4\n\nCount on from two.")
        XCTAssertEqual(wrong.reps, 0)
        XCTAssertNotNil(NeedsWork.card(question: quiz, correct: nil, dontKnow: true, confidence: nil))
        // Right but unsure is a lucky guess; right and sure is solid.
        XCTAssertNotNil(NeedsWork.card(question: quiz, correct: true, dontKnow: false, confidence: 50))
        XCTAssertNil(NeedsWork.card(question: quiz, correct: true, dontKnow: false, confidence: 51))
        XCTAssertNil(NeedsWork.card(question: quiz, correct: true, dontKnow: false, confidence: nil))
        XCTAssertNil(NeedsWork.card(question: ToolCall(id: "x", name: "quiz", arguments: "{}"), correct: false, dontKnow: false, confidence: nil))
    }

    func testProblemsNeedingHelpBecomeCards() {
        let problem = ToolCall(id: "p", name: "problem", arguments: #"{"statement":"Solve $x+1=3$.","mode":"recall","modelSolution":"$x=2$"}"#)
        for outcome in ["surrendered", "movedOn", "solvedWithHints"] {
            let card = NeedsWork.card(problem: problem, outcome: outcome)
            XCTAssertEqual(card?.front, "Solve $x+1=3$.", outcome)
            XCTAssertEqual(card?.back, "$x=2$", outcome)
        }
        XCTAssertNil(NeedsWork.card(problem: problem, outcome: "solved"))
        XCTAssertNil(NeedsWork.card(problem: problem, outcome: "dismissed"))
    }

    func testNeedsWorkSkipsDuplicates() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("needs-work-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FlashcardStore(file: file)
        let card = try XCTUnwrap(NeedsWork.card(question: quiz, correct: false, dontKnow: false, confidence: nil))
        store.addNeedsWork(card)
        store.addNeedsWork(try XCTUnwrap(NeedsWork.card(question: quiz, correct: false, dontKnow: false, confidence: nil)))
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(FlashcardStore(file: file).cards.count, 1)
    }

    // MARK: drawing

    func testDrawingRendersInkOnWhite() throws {
        let canvas = PKCanvasView()
        XCTAssertNil(DrawingPad.render(canvas))
        let points = [CGPoint(x: 40, y: 40), CGPoint(x: 240, y: 140)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let image = try XCTUnwrap(DrawingPad.render(canvas))
        XCTAssertEqual(image.size.width, canvas.drawing.bounds.width + 48, accuracy: 1)
        // A corner is margin, so it's the white page; JPEG must not turn transparency black.
        let jpeg = try XCTUnwrap(PendingAttachments.jpeg(image).flatMap(UIImage.init(data:))?.cgImage)
        let corner = try XCTUnwrap(jpeg.cropping(to: CGRect(x: 0, y: 0, width: 4, height: 4)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 200)
        XCTAssertGreaterThan(pixel[2], 200)
    }

    // MARK: your own server

    func testServerAddresses() {
        XCTAssertEqual(Prefs.serverURL("http://192.168.1.20:11434"), "http://192.168.1.20:11434/v1")
        XCTAssertEqual(Prefs.serverURL(" http://mac.local:1234/v1/ "), "http://mac.local:1234/v1")
        XCTAssertEqual(Prefs.serverURL("https://llm.example.com/api/v1/chat/completions"), "https://llm.example.com/api/v1")
        XCTAssertNil(Prefs.serverURL(""))
        XCTAssertNil(Prefs.serverURL("192.168.1.20:11434"))
        XCTAssertNil(Prefs.serverURL("ftp://192.168.1.20"))
        XCTAssertNil(Prefs.serverURL("http://"))
        XCTAssertNil(Prefs.serverURL("http://user:pw@host:1234"))
    }

    func testOwnServerRequests() async throws {
        let saved = Prefs.d.string(forKey: Prefs.customServer)
        defer { Prefs.d.set(saved, forKey: Prefs.customServer) }
        Prefs.d.removeObject(forKey: Prefs.customServer)
        do {
            _ = try await LLMClient.credential(for: .custom)
            XCTFail("a server with no address can't be used")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("address"))
        }
        Prefs.d.set("http://10.0.0.5:1234", forKey: Prefs.customServer)
        XCTAssertEqual(ProviderID.custom.baseURL(.chat), "http://10.0.0.5:1234/v1")
        let credential = try await LLMClient.credential(for: .custom)
        XCTAssertNotNil(credential)

        // Keyless servers get no Authorization header; reasoning options other servers reject aren't sent.
        var req = URLRequest(url: URL(string: "http://10.0.0.5:1234/v1/models")!)
        LLMClient.authorize(&req, provider: .custom, wire: .chat, key: "")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        LLMClient.authorize(&req, provider: .custom, wire: .chat, key: "sk-local")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-local")
        let body = LLMClient.chatBody(model: "qwen3:8b", provider: .custom, system: "s", messages: [Message(role: .user, text: "hi")],
                                      tools: [], options: RequestOptions(effort: .high))
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertFalse(RequestOptions.fastSupported(ModelRef(provider: .custom, id: "x", wire: .chat)))
        XCTAssertEqual(ModelCatalog.entry(.custom, .chat, ["id": "llama3.2:3b"])?.group, "On your server")
        XCTAssertTrue(ProviderID.keyProviders.contains(.custom))
    }

    // MARK: link browser

    func testLinkBrowsers() {
        let page = URL(string: "https://example.com/a?b=1")!
        XCTAssertNil(LinkBrowser.safari.link(to: page))
        XCTAssertEqual(LinkBrowser.chrome.link(to: page)?.absoluteString, "googlechromes://example.com/a?b=1")
        XCTAssertEqual(LinkBrowser.chrome.link(to: URL(string: "http://example.com")!)?.absoluteString, "googlechrome://example.com")
        XCTAssertNil(LinkBrowser.chrome.link(to: URL(string: "mailto:a@b.c")!))
        XCTAssertEqual(LinkBrowser.reynard.link(to: page), ChatGPTAuth.reynardURL(page))

        // The old Reynard switch carries over until a browser is picked.
        let saved = (Prefs.d.object(forKey: Prefs.linkBrowser), Prefs.d.object(forKey: Prefs.reynardLinks))
        defer { Prefs.d.set(saved.0, forKey: Prefs.linkBrowser); Prefs.d.set(saved.1, forKey: Prefs.reynardLinks) }
        Prefs.d.removeObject(forKey: Prefs.linkBrowser)
        Prefs.d.set(true, forKey: Prefs.reynardLinks)
        XCTAssertEqual(Prefs.linkBrowserValue, .reynard)
        Prefs.d.set(false, forKey: Prefs.reynardLinks)
        XCTAssertEqual(Prefs.linkBrowserValue, .safari)
        Prefs.d.set("chrome", forKey: Prefs.linkBrowser)
        XCTAssertEqual(Prefs.linkBrowserValue, .chrome)
    }

    // MARK: timed exam

    func testTimedAttempt() throws {
        let now = Date()
        var s = Session(kind: .exam, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))
        XCTAssertFalse(s.examRunning(at: now))
        s.examEnds = now.addingTimeInterval(90)
        XCTAssertTrue(s.examRunning(at: now))
        XCTAssertFalse(s.examRunning(at: now.addingTimeInterval(91)))
        s.kind = .chat
        XCTAssertFalse(s.examRunning(at: now))

        let prompt = Prompts.timedExam(until: now.addingTimeInterval(90), now: now)
        XCTAssertTrue(prompt.contains("2 minutes left"))
        XCTAssertTrue(prompt.contains("invigilator"))
        XCTAssertTrue(Prompts.timedExam(until: now.addingTimeInterval(30), now: now).contains("1 minute left"))

        // Sessions saved before the timer existed still open.
        let json = #"{"id":"6E0C3B7E-1111-4222-8333-444455556666","title":"Old","kind":"exam","model":{"provider":"openrouter","id":"x","wire":"chat"},"messages":[],"created":800000000,"savedToKnowledge":false}"#
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: Data(json.utf8)).examEnds)
    }

    func testTimerStartsAndEnds() {
        let app = AppState()
        app.sessions = [Session(kind: .exam, model: ModelRef(provider: .openrouter, id: "x", wire: .chat))]
        let id = app.sessions[0].id
        app.startExam(minutes: 30, for: id)
        XCTAssertEqual(app.sessions[0].examEnds?.timeIntervalSinceNow ?? 0, 1800, accuracy: 5)
        app.endExam(id, timeUp: true)
        XCTAssertNil(app.sessions[0].examEnds)
        XCTAssertNotNil(app.notice)
        SessionStore.delete(app.sessions[0])
    }
}
