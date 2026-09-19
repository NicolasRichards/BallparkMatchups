import XCTest
@testable import PatchCore

/// Regression tests built from frames Gameday actually sent during a live
/// game (LAD–SF, 2026-09-19). Written because the synthesised decoder rejected
/// every real frame and the push path silently did nothing.
final class GamedayPushEventTests: XCTestCase {

    private func decode(_ json: String) throws -> GamedayPushEvent {
        try JSONDecoder().decode(GamedayPushEvent.self, from: Data(json.utf8))
    }

    /// Captured verbatim off the socket. `gamePk` arrives as a quoted string
    /// even though MLB's own typings call it a number; decoding it as Int threw
    /// and took the whole frame with it.
    func testRealFrameWithStringGamePk() throws {
        let event = try decode(#"""
        {"timeStamp":"20260919_044730","gamePk":"823898",
         "updateId":"35d55aae-ed0b-470f-94d5-5874a4c997d5","wait":10,
         "logicalEvents":["countChange","count01","pitcherChange"]}
        """#)
        XCTAssertEqual(event.updateId, "35d55aae-ed0b-470f-94d5-5874a4c997d5")
        XCTAssertEqual(event.gamePk, 823898)
        XCTAssertEqual(event.timeStamp, "20260919_044730")
        XCTAssertEqual(event.logicalEvents?.count, 3)
        // Absent, not a failure.
        XCTAssertNil(event.gameEvents)
        XCTAssertFalse(event.isGameFinished)
        XCTAssertFalse(event.isFullRefresh)
    }

    /// The same field as a bare number must keep working, in case MLB ever
    /// matches its own documentation.
    func testNumericGamePkStillDecodes() throws {
        let event = try decode(#"{"updateId":"abc","gamePk":823898}"#)
        XCTAssertEqual(event.gamePk, 823898)
    }

    /// Only updateId is load-bearing — diffPatch cannot be called without it.
    func testUpdateIdIsTheOnlyRequirement() throws {
        let event = try decode(#"{"updateId":"abc"}"#)
        XCTAssertEqual(event.updateId, "abc")
        XCTAssertNil(event.gamePk)
        XCTAssertNil(event.timeStamp)

        XCTAssertThrowsError(try decode(#"{"gamePk":"823898"}"#))
    }

    /// An unexpected type anywhere else must not sink the frame.
    func testSurprisingTypesElsewhereAreTolerated() throws {
        let event = try decode(#"""
        {"updateId":"abc","gamePk":{"nested":true},"timeStamp":99,
         "gameEvents":"not-an-array","logicalEvents":["countChange"],
         "changeEvent":"not-an-object"}
        """#)
        XCTAssertEqual(event.updateId, "abc")
        XCTAssertNil(event.gamePk)
        XCTAssertNil(event.timeStamp)
        XCTAssertNil(event.gameEvents)
        XCTAssertNil(event.changeEvent)
        XCTAssertEqual(event.logicalEvents, ["countChange"])
    }

    func testFullRefreshAndGameFinishedAreRecognised() throws {
        let refresh = try decode(#"""
        {"updateId":"abc","changeEvent":{"type":"full_refresh"}}
        """#)
        XCTAssertTrue(refresh.isFullRefresh)

        let finished = try decode(#"""
        {"updateId":"abc","gameEvents":["game_finished"]}
        """#)
        XCTAssertTrue(finished.isGameFinished)

        let ordinary = try decode(#"""
        {"updateId":"abc","changeEvent":{"type":"diff_patch"},
         "gameEvents":["pitch"]}
        """#)
        XCTAssertFalse(ordinary.isFullRefresh)
        XCTAssertFalse(ordinary.isGameFinished)
    }
}
