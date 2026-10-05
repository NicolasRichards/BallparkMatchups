import XCTest
@testable import PatchCore

/// `scheduledInnings` is what tells the end-of-game logic which inning is the
/// last one. Nine is only the usual answer — a doubleheader's games are seven.
/// The shape here is taken from captured MLB feeds, where the field sits at
/// `/liveData/linescore/scheduledInnings`.
final class LinescoreTests: XCTestCase {

    private typealias Linescore = LiveFeedResponse.LiveData.Linescore

    private func decode(_ json: String) throws -> Linescore {
        try JSONDecoder().decode(Linescore.self, from: Data(json.utf8))
    }

    func testDecodesTheUsualNine() throws {
        let ls = try decode(#"""
        {"currentInning":9,"currentInningOrdinal":"9th","inningState":"End",
         "scheduledInnings":9,"balls":0,"strikes":0,"outs":3}
        """#)
        XCTAssertEqual(ls.scheduledInnings, 9)
        XCTAssertEqual(ls.currentInning, 9)
        XCTAssertEqual(ls.inningState, "End")
    }

    func testDecodesASevenInningGame() throws {
        let ls = try decode(#"{"currentInning":7,"inningState":"End","scheduledInnings":7}"#)
        XCTAssertEqual(ls.scheduledInnings, 7)
    }

    /// Absent rather than wrong: the caller keeps its own default of nine
    /// rather than treating a missing field as the end of the game.
    func testAMissingFieldDecodesToNil() throws {
        let ls = try decode(#"{"currentInning":3,"inningState":"Top"}"#)
        XCTAssertNil(ls.scheduledInnings)
        XCTAssertEqual(ls.currentInning, 3)
    }
}
