import XCTest
@testable import PatchCore

/// Regression tests for the end-of-game stall.
///
/// Reported on three games running: the last out lands and the card stops
/// updating — it never shows the third out and never shows the final. Backing
/// out to the game list showed the game as ended, and going back in showed it
/// ended too, so the data was there; only the card's next poll was minutes
/// away. Waiting long enough did eventually fix it, which is exactly the
/// signature of an interval that is too long rather than a feed that is wrong.
final class PollScheduleTests: XCTestCase {

    // MARK: Fixtures

    private func inputs(
        _ state: GameUIState,
        pushIsHealthy: Bool = false,
        gameEndAnnounced: Bool = false,
        scheduledInnings: Int = 9,
        betweenInningsStart: Date? = nil,
        sawBreakStart: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> PollSchedule.Inputs {
        PollSchedule.Inputs(
            state: state,
            pushIsHealthy: pushIsHealthy,
            gameEndAnnounced: gameEndAnnounced,
            scheduledInnings: scheduledInnings,
            betweenInningsStart: betweenInningsStart,
            sawBreakStart: sawBreakStart,
            now: now
        )
    }

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func breakState(inning: Int, _ half: String = "End") -> GameUIState {
        .betweenInnings(BetweenInningsInfo(
            inning: inning,
            inningState: half,
            nextTeam: "SF",
            venueName: "Oracle Park"
        ))
    }

    private func liveState() -> GameUIState {
        let player = PlayerInfo(
            id: 1, fullName: "Test Player", primaryPosition: "3B",
            batSide: .right, pitchHand: nil, heightFeet: nil, heightInches: nil,
            weightLbs: nil, birthDate: nil, teamAbbreviation: "SF"
        )
        return .live(MatchupCard(
            batter: player,
            pitcher: player,
            situation: SituationStrip(
                inning: 9, inningState: "Bottom", outs: 2,
                runners: .empty, balls: 0, strikes: 2
            ),
            bvp: nil, batterSplits: [], pitcherSplit: nil,
            batterGame: nil, pitcherGame: nil, lastEvent: nil
        ))
    }

    private func finalState() -> GameUIState {
        .final_(FinalInfo(
            homeTeam: "SF", awayTeam: "LAD", homeScore: 4, awayScore: 3,
            winnerName: nil, winnerRecord: nil, loserName: nil,
            loserRecord: nil, saveName: nil
        ))
    }

    // MARK: The reported bug

    /// The socket announces the game is over and then closes, so the poll loop
    /// is the only thing left that can see the switch to Final. MLB keeps
    /// reporting "In Progress" for a few seconds past the last out, and the
    /// 60s socket net held a stale matchup up for most of a minute.
    func testLiveStateChecksQuicklyOnceTheGameEndIsAnnounced() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(liveState(), pushIsHealthy: true,
                                         gameEndAnnounced: true)), 5)
    }

    /// The last out of the ninth looks exactly like any other half-inning
    /// break, so the card settled onto the two-minute timer for an inning that
    /// was never coming. This is the path with no socket at all.
    func testEndOfTheFinalInningDoesNotWaitOutTheBreakTimer() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 9),
                                         betweenInningsStart: now,
                                         sawBreakStart: true)), 5)
    }

    /// Extra innings cost a handful of extra polls, which is the right trade
    /// for showing the final promptly.
    func testExtraInningsKeepChecking() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 12),
                                         betweenInningsStart: now,
                                         sawBreakStart: true)), 5)
    }

    /// A doubleheader's short game ends at the seventh, which is why the
    /// comparison reads the feed's `scheduledInnings` instead of assuming nine.
    func testAShortGameEndsAtItsOwnScheduledLength() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 7),
                                         scheduledInnings: 7,
                                         betweenInningsStart: now,
                                         sawBreakStart: true)), 5)
    }

    /// The same seventh inning in a nine-inning game is an ordinary break.
    func testTheSeventhOfANineInningGameIsAnOrdinaryBreak() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 7),
                                         betweenInningsStart: now,
                                         sawBreakStart: true)), 120)
    }

    /// A game called early is announced the same way, mid-game.
    func testAnAnnouncedEndOverridesTheBreakTimerMidGame() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 4),
                                         gameEndAnnounced: true,
                                         betweenInningsStart: now,
                                         sawBreakStart: true)), 5)
    }

    /// A suspended or delayed game that MLB then calls must not sit on 60s.
    func testADelayedGameChecksQuicklyOnceTheEndIsAnnounced() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(.delay(DelayInfo(reason: "Rain", isPreGame: false)),
                                         gameEndAnnounced: true)), 5)
        XCTAssertEqual(
            PollSchedule.interval(inputs(.delay(DelayInfo(reason: "Rain", isPreGame: false)))), 60)
    }

    // MARK: Behaviour that must not have changed

    func testLiveStateLeansOnTheSocketWhileItIsHealthy() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(liveState(), pushIsHealthy: true)), 60)
    }

    func testLiveStateIsTightWithoutAHealthySocket() {
        XCTAssertEqual(PollSchedule.interval(inputs(liveState())), 5)
    }

    func testTheBreakTimerCountsDownAndThenGoesTight() {
        // 30s into a two-minute break: 90s left.
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 4),
                                         betweenInningsStart: now.addingTimeInterval(-30),
                                         sawBreakStart: true,
                                         now: now)), 90)
        // 118s in: the first pitch is imminent, so check every 5s.
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 4),
                                         betweenInningsStart: now.addingTimeInterval(-118),
                                         sawBreakStart: true,
                                         now: now)), 5)
    }

    /// Opened into a break already in progress: its remaining length is
    /// unknown, so check often rather than guess.
    func testOpeningIntoABreakChecksOften() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 4),
                                         betweenInningsStart: now,
                                         sawBreakStart: false)), 20)
    }

    func testTerminalStatesStopTheLoop() {
        XCTAssertEqual(PollSchedule.interval(inputs(finalState())), .infinity)
        XCTAssertEqual(PollSchedule.interval(inputs(.postponed("Rain"))), .infinity)
        XCTAssertEqual(PollSchedule.interval(inputs(.cancelled("Rain"))), .infinity)
        // Still terminal with the flag set — Final is Final.
        XCTAssertEqual(
            PollSchedule.interval(inputs(finalState(), gameEndAnnounced: true)), .infinity)
    }

    func testPreGameTightensAsFirstPitchApproaches() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(.preGame(preGameInfo(firstPitch: now.addingTimeInterval(600))),
                                         now: now)), 30)
        XCTAssertEqual(
            PollSchedule.interval(inputs(.preGame(preGameInfo(firstPitch: now.addingTimeInterval(3600))),
                                         now: now)), 300)
        XCTAssertEqual(
            PollSchedule.interval(inputs(.preGame(preGameInfo(firstPitch: nil)), now: now)), 300)
    }

    func testLoadingRetriesSoon() {
        XCTAssertEqual(PollSchedule.interval(inputs(.loading)), 12)
    }

    private func preGameInfo(firstPitch: Date?) -> PreGameInfo {
        PreGameInfo(
            venueName: "Oracle Park", homeTeam: "SF", awayTeam: "LAD",
            firstPitch: firstPitch, homePitcher: nil, awayPitcher: nil,
            homeHand: nil, awayHand: nil
        )
    }
}
