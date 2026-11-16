import XCTest
@testable import PatchCore

/// A card built while a stats request was failing gets its missing stats
/// retried a few times, further apart each time.
///
/// Two failures bracket this. Recording the bare card and never going back
/// left one dropped request showing for a whole at-bat. Refusing to build the
/// card until every request succeeded left the *previous* batter's card up
/// for as long as a request kept failing, and re-sent it on every update.
final class StatsRetryTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func tick(atBat: Int = 40, batter: Int = 1, pitcher: Int = 2, strikes: Int = 0) -> TickState {
        TickState(
            atBatIndex: atBat, batterId: batter, pitcherId: pitcher,
            balls: 0, strikes: strikes, outs: 1,
            runners: .empty, inningState: "Top", halfInning: 5
        )
    }

    func testTheFirstRetryWaitsFiveSeconds() {
        let retry = StatsRetry(tick: tick(), now: start)
        XCTAssertFalse(retry.isDue(for: tick(), now: start))
        XCTAssertFalse(retry.isDue(for: tick(), now: start.addingTimeInterval(4.9)))
        XCTAssertTrue(retry.isDue(for: tick(), now: start.addingTimeInterval(5)))
    }

    /// The count changing mid-at-bat does not make it a different at-bat.
    func testTheCountDoesNotMatter() {
        let retry = StatsRetry(tick: tick(), now: start)
        XCTAssertTrue(retry.isDue(for: tick(strikes: 2), now: start.addingTimeInterval(6)))
    }

    func testEachRetryWaitsTwiceAsLong() {
        var retry = StatsRetry(tick: tick(), now: start)

        let first = start.addingTimeInterval(5)
        retry.noteRetry(now: first)
        XCTAssertFalse(retry.isDue(for: tick(), now: first.addingTimeInterval(9.9)))
        XCTAssertTrue(retry.isDue(for: tick(), now: first.addingTimeInterval(10)))

        let second = first.addingTimeInterval(10)
        retry.noteRetry(now: second)
        XCTAssertFalse(retry.isDue(for: tick(), now: second.addingTimeInterval(19.9)))
        XCTAssertTrue(retry.isDue(for: tick(), now: second.addingTimeInterval(20)))
    }

    /// A request that fails every time is given up on, not re-sent on every
    /// pitch for the rest of the at-bat.
    func testItGivesUpAfterThreeRetries() {
        var retry = StatsRetry(tick: tick(), now: start)
        for _ in 0..<StatsRetry.limit { retry.noteRetry(now: start) }
        XCTAssertEqual(retry.attempts, 3)
        XCTAssertFalse(retry.isDue(for: tick(), now: start.addingTimeInterval(3600)))
    }

    /// Another batter, another pitcher, or the same two meeting again later
    /// in the game: none of them inherit this at-bat's record.
    func testItOnlyCoversItsOwnAtBat() {
        let retry = StatsRetry(tick: tick(), now: start)
        let later = start.addingTimeInterval(60)
        XCTAssertFalse(retry.isDue(for: tick(batter: 9), now: later))
        XCTAssertFalse(retry.isDue(for: tick(pitcher: 9), now: later))
        XCTAssertFalse(retry.isDue(for: tick(atBat: 71), now: later))
        XCTAssertTrue(retry.covers(tick(strikes: 1)))
        XCTAssertFalse(retry.covers(tick(atBat: 71)))
    }
}
