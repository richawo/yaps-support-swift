import XCTest
@testable import YapsSupport

/// Rating cards (§5): decoding, the score, and the strings they show.
final class RatingCardTests: XCTestCase {
    private let context = ChatPresentation.Context(customerLanguage: "en", agentReadSeq: 0, isPaywallAvailable: { _ in false },
                                                   isScreenAvailable: { _ in false }, fileURL: { URL(fileURLWithPath: "/tmp/\($0)") })

    private func message(rating: Any?) throws -> Message {
        var card: [String: Any] = ["type": "rating", "buttonLabel": "Rate", "available": true]
        if let rating { card["rating"] = rating }
        let json: [String: Any] = ["id": "msg_r", "conversationId": "cnv_1", "seq": 9, "author": ["type": "agent"], "kind": "card",
                                   "text": "How did we do?", "attachments": [], "card": card, "createdAt": "2026-11-02T10:00:00.000Z"]
        return try WireJSON.decoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testUnratedAndRatedCards() throws {
        XCTAssertEqual(ChatPresentation.row(for: try message(rating: nil), context: context).card, .rating(score: nil))
        XCTAssertEqual(ChatPresentation.row(for: try message(rating: 4), context: context).card, .rating(score: 4))
        XCTAssertEqual(ChatPresentation.row(for: try message(rating: 9), context: context).card, .rating(score: nil), "Out of range shows the stars again")
    }

    func testRatingStrings() {
        XCTAssertEqual(Strings(language: "en").format("card.ratingStars", 4), "4 out of 5")
        XCTAssertEqual(Strings(language: "de")("card.ratingThanks"), "Danke für deine Bewertung!")
    }

    func testRateRequestBody() throws {
        let data = try JSONEncoder().encode(RateRequest(score: 5))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: AnyHashable], ["action": "rate", "score": 5])
    }
}
