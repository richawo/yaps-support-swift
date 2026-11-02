import XCTest
@testable import YapsSupport

/// The in-app review prompt: reading it, claiming it once, and recording answers.
@MainActor
final class ReviewPromptTests: XCTestCase {
    private var harness: EngineHarness!
    private var engine: SupportEngine { harness.engine }

    override func setUp() async throws {
        harness = EngineHarness()
        harness.stubRegister()
    }

    override func tearDown() async throws {
        harness.cleanUp()
    }

    func testReadsTheDuePrompt() async throws {
        harness.transport.on("GET", "/v1/sdk/review-prompt", json: ["prompt": [
            "milestone": 100, "count": 104, "title": "Enjoying Yaps?", "body": "A quick review helps.",
            "buttonLabel": "Leave a rating", "url": "https://apps.apple.com/app/id1?action=write-review", "shown": false,
        ]])
        let due = await engine.reviewPrompt()
        let prompt = try XCTUnwrap(due)
        XCTAssertEqual(prompt.milestone, 100)
        XCTAssertEqual(prompt.count, 104)
        XCTAssertEqual(prompt.url, URL(string: "https://apps.apple.com/app/id1?action=write-review"))
        XCTAssertFalse(prompt.shown)
    }

    func testNoPromptIsNil() async {
        harness.transport.on("GET", "/v1/sdk/review-prompt", json: ["prompt": NSNull()])
        let prompt = await engine.reviewPrompt()
        XCTAssertNil(prompt)
    }

    func testClaimAndAnswersAreSent() async throws {
        harness.transport.on("POST", "/v1/sdk/review-prompt", json: ["claimed": true])
        harness.transport.on("POST", "/v1/sdk/review-prompt", json: ["claimed": false])
        harness.transport.on("POST", "/v1/sdk/review-prompt", json: [:])
        let won = await engine.reviewPromptAction("shown", milestone: 100)
        let lost = await engine.reviewPromptAction("shown", milestone: 100)
        XCTAssertTrue(won)
        XCTAssertFalse(lost)
        await engine.reviewPromptAction(ReviewPromptAnswer.optedOut.rawValue, milestone: 100)
        let bodies = harness.transport.requests("POST", "/v1/sdk/review-prompt").compactMap(\.json)
        XCTAssertEqual(bodies.map { $0["action"] as? String }, ["shown", "shown", "opted_out"])
        XCTAssertEqual(bodies.map { $0["milestone"] as? Int }, [100, 100, 100])
    }
}
