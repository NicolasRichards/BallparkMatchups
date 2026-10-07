import XCTest
@testable import PatchCore

/// The rule that decides a game is over before MLB says so.
///
/// Written after a Fall League game went to extras: Glendale led 4–3 at the
/// end of the 10th and the card sat on "GDD coming to bat" for about two
/// minutes. The old check only ended a game when the *home* team led, so an
/// away-team win in the last inning went unnoticed.
final class GameCompletionTests: XCTestCase {

    private func isOver(_ inning: Int, _ state: String,
                        home: Int, away: Int, scheduled: Int = 9) -> Bool {
        GameCompletion.isOver(inning: inning, inningState: state,
                              scheduledInnings: scheduled,
                              homeRuns: home, awayRuns: away)
    }

    // MARK: End of an inning — the bottom half is complete

    /// The reported case, verbatim: GDD 4, MSS 3, end of the 10th.
    func testAwayTeamLeadingAtTheEndOfExtrasEndsTheGame() {
        XCTAssertTrue(isOver(10, "End", home: 3, away: 4))
    }

    func testHomeTeamLeadingAtTheEndOfExtrasEndsTheGame() {
        XCTAssertTrue(isOver(10, "End", home: 4, away: 3))
    }

    func testATieAtTheEndOfExtrasPlaysOn() {
        XCTAssertFalse(isOver(10, "End", home: 4, away: 4))
    }

    func testEitherTeamLeadingAtTheEndOfTheNinthEndsTheGame() {
        XCTAssertTrue(isOver(9, "End", home: 2, away: 1))
        XCTAssertTrue(isOver(9, "End", home: 1, away: 2))
    }

    func testATieAtTheEndOfTheNinthPlaysOn() {
        XCTAssertFalse(isOver(9, "End", home: 1, away: 1))
    }

    // MARK: Middle of an inning — the home team has yet to bat

    /// The home team does not need to bat, so its lead ends the game.
    func testHomeLeadingAtTheMiddleEndsTheGame() {
        XCTAssertTrue(isOver(9, "Middle", home: 5, away: 2))
        XCTAssertTrue(isOver(11, "Middle", home: 5, away: 2))
    }

    /// The home team still gets its half, however far behind it is.
    func testAwayLeadingAtTheMiddlePlaysOn() {
        XCTAssertFalse(isOver(9, "Middle", home: 2, away: 5))
        XCTAssertFalse(isOver(11, "Middle", home: 2, away: 5))
    }

    func testATieAtTheMiddlePlaysOn() {
        XCTAssertFalse(isOver(9, "Middle", home: 3, away: 3))
    }

    // MARK: Before the last scheduled inning

    func testNothingBeforeTheLastScheduledInningEndsTheGame() {
        for state in ["End", "Middle", "Top", "Bottom"] {
            XCTAssertFalse(isOver(8, state, home: 9, away: 0), state)
            XCTAssertFalse(isOver(1, state, home: 0, away: 9), state)
        }
    }

    /// A doubleheader's short game reaches its last inning at the seventh.
    func testAShortGameEndsAtItsOwnScheduledLength() {
        XCTAssertTrue(isOver(7, "End", home: 3, away: 1, scheduled: 7))
        XCTAssertFalse(isOver(7, "End", home: 3, away: 1, scheduled: 9))
    }

    // MARK: Mid-inning states decide nothing

    /// A walk-off is a "Bottom", and the feed reports the run before it
    /// reports the state change. Ending the game here would call it early.
    func testMidInningStatesNeverEndTheGame() {
        XCTAssertFalse(isOver(9, "Bottom", home: 5, away: 2))
        XCTAssertFalse(isOver(9, "Top", home: 5, away: 2))
        XCTAssertFalse(isOver(12, "Bottom", home: 1, away: 0))
    }
}
