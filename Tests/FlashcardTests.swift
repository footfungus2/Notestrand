import XCTest
@testable import Notestrand

final class FlashcardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(interval: Double = 0, ease: Double = 2.5, reps: Int = 0) -> Flashcard {
        Flashcard(front: "What is contribution?", back: "Price minus variable cost.", deck: "Business",
                  due: now, interval: interval, ease: ease, reps: reps)
    }

    func testAgainGoodGoodEasyTransitions() {
        let original = card(interval: 8, reps: 3)
        let again = Scheduler.review(original, .again, now: now)
        XCTAssertEqual(again.id, original.id)
        XCTAssertEqual(again.interval, 0)
        XCTAssertEqual(again.due, now.addingTimeInterval(600))
        XCTAssertEqual(again.reps, 0)
        XCTAssertEqual(again.ease, 2.3, accuracy: 0.000001)
        XCTAssertEqual(original.interval, 8)

        let first = Scheduler.review(again, .good, now: now)
        XCTAssertEqual(first.interval, 1)
        XCTAssertEqual(first.due, now.addingTimeInterval(86_400))
        XCTAssertEqual(first.reps, 1)
        let second = Scheduler.review(first, .good, now: now)
        XCTAssertEqual(second.interval, 3)
        XCTAssertEqual(second.due, now.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(second.reps, 2)
        let easy = Scheduler.review(second, .easy, now: now)
        XCTAssertEqual(easy.interval, 3 * 2.3 * 1.3, accuracy: 0.000001)
        XCTAssertEqual(easy.ease, 2.45, accuracy: 0.000001)
        XCTAssertEqual(easy.reps, 3)
        XCTAssertEqual(easy.due.timeIntervalSince(now), easy.interval * 86_400, accuracy: 0.000001)
        XCTAssertEqual(Scheduler.review(second, .good, now: now).interval, 6.9, accuracy: 0.000001)
    }

    func testHardIntervalsAndEaseFloor() {
        let hard = Scheduler.review(card(ease: 1.35), .hard, now: now)
        XCTAssertEqual(hard.interval, 1)
        XCTAssertEqual(hard.ease, 1.3)
        XCTAssertEqual(hard.reps, 1)
        XCTAssertEqual(hard.due, now.addingTimeInterval(86_400))
        XCTAssertEqual(Scheduler.review(card(interval: 5, reps: 2), .hard, now: now).interval, 6)
        var repeated = hard
        for _ in 0..<10 {
            repeated = Scheduler.review(repeated, .again, now: now)
            repeated = Scheduler.review(repeated, .hard, now: now)
        }
        XCTAssertEqual(repeated.ease, 1.3)
        XCTAssertEqual(Scheduler.review(card(), .easy, now: now).interval, 1.3)
        XCTAssertEqual(Scheduler.review(card(interval: 1, reps: 1), .easy, now: now).interval, 3.9, accuracy: 0.000001)
    }

    func testParseFencedReply() throws {
        let before = Date()
        let cards = FlashcardGenerator.parse("""
        ```json
        [{"front":" What is contribution? ","back":"Price minus variable cost."},
         {"front":"What is profit?","back":"Revenue minus total costs."}]
        ```
        """, deck: "Business")
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.first?.front, "What is contribution?")
        XCTAssertEqual(cards.first?.back, "Price minus variable cost.")
        XCTAssertEqual(Set(cards.map(\.id)).count, 2)
        for card in cards {
            XCTAssertEqual(card.deck, "Business")
            XCTAssertEqual(card.interval, 0)
            XCTAssertEqual(card.ease, 2.5)
            XCTAssertEqual(card.reps, 0)
            XCTAssertGreaterThanOrEqual(card.due, before)
            XCTAssertLessThanOrEqual(card.due, Date())
        }
        XCTAssertEqual(try JSONDecoder().decode([Flashcard].self, from: JSONEncoder().encode(cards)), cards)
    }

    func testParseLeadingProseAndRejectInvalidCards() {
        let cards = FlashcardGenerator.parse("""
        Here are your revision cards:
        [{"front":"Capital of France?","back":"**Paris**"},
         {"front":"   ","back":"Empty question"}, {"front":"Missing answer"},
         {"front":42,"back":"Wrong type"}, null]
        Happy revising!
        """, deck: "Geography")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.deck, "Geography")
        XCTAssertEqual(cards.first?.back, "**Paris**")
        for invalid in ["No JSON", "[]", "] before [", "[{invalid}]", "[{\"front\":\"Q\",\"back\":\" \"}]"] {
            XCTAssertTrue(FlashcardGenerator.parse(invalid, deck: "Invalid").isEmpty)
        }
    }

    func testEmptySessionGenerationFailsWithoutCallingTheModel() async {
        let session = Session(kind: .chat, model: ModelRef(provider: .openrouter, id: "unused", wire: .chat))
        do {
            _ = try await FlashcardGenerator.generate(from: session)
            XCTFail("An empty session should not generate cards")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no conversation"))
        }
    }

    @MainActor
    func testStorePersistsUpdatesDeletesAndOrdersDueCards() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("flashcards.json")
        let store = FlashcardStore(file: file)
        var oldest = card()
        oldest.due = Date().addingTimeInterval(-120)
        var recent = card()
        recent.due = Date().addingTimeInterval(-60)
        var future = card()
        future.due = Date().addingTimeInterval(86_400)
        store.add([future, recent, oldest])
        XCTAssertNil(store.error)
        XCTAssertEqual(store.due.map(\.id), [oldest.id, recent.id])
        XCTAssertEqual(FlashcardStore(file: file).cards, store.cards)

        let reviewed = Scheduler.review(oldest, .good)
        store.update(reviewed)
        XCTAssertEqual(store.due.map(\.id), [recent.id])
        XCTAssertEqual(FlashcardStore(file: file).cards.last, reviewed)
        store.delete(recent.id)
        XCTAssertEqual(FlashcardStore(file: file).cards.map(\.id), [future.id, oldest.id])
    }

    @MainActor
    func testStoreKeepsUnreadableDataAndReportsWriteFailures() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let corruptFile = folder.appendingPathComponent("corrupt.json")
        let original = Data("unreadable saved flashcards".utf8)
        try original.write(to: corruptFile)
        let corruptStore = FlashcardStore(file: corruptFile)
        corruptStore.add([card()])
        XCTAssertNotNil(corruptStore.error)
        XCTAssertTrue(corruptStore.cards.isEmpty)
        XCTAssertEqual(try Data(contentsOf: corruptFile), original)

        let missingFolder = folder.appendingPathComponent("missing")
        let store = FlashcardStore(file: missingFolder.appendingPathComponent("flashcards.json"))
        XCTAssertNil(store.error)
        store.add([card()])
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.cards.isEmpty)
        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        store.add([card()])
        XCTAssertNil(store.error)
        XCTAssertEqual(store.cards.count, 1)
    }
}
