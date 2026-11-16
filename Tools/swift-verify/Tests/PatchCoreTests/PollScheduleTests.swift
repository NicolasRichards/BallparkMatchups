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
            winnerName: nil, loserName: nil, saveName: nil
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

    /// Without a socket, extra innings keep checking: more polls, which is
    /// the right trade for showing the final promptly.
    func testExtraInningsKeepChecking() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 12),
                                         betweenInningsStart: now,
                                         sawBreakStart: true)), 5)
    }

    /// With patches arriving, the socket announces the end and the linescore
    /// has already said the game goes on, so a late break is an ordinary one:
    /// checking every 5s re-downloaded the whole feed ~24 times per break.
    func testALateBreakLeansOnAHealthySocket() {
        for inning in [9, 12] {
            XCTAssertEqual(
                PollSchedule.interval(inputs(breakState(inning: inning),
                                             pushIsHealthy: true,
                                             betweenInningsStart: now,
                                             sawBreakStart: true,
                                             now: now)), 120)
        }
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 7),
                                         pushIsHealthy: true,
                                         scheduledInnings: 7,
                                         betweenInningsStart: now.addingTimeInterval(-30),
                                         sawBreakStart: true,
                                         now: now)), 90)
    }

    /// The socket's own word that the game is over still wins, healthy or not.
    func testAnAnnouncedEndOverridesAHealthySocketAtALateBreak() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(breakState(inning: 9),
                                         pushIsHealthy: true,
                                         gameEndAnnounced: true,
                                         betweenInningsStart: now,
                                         sawBreakStart: true,
                                         now: now)), 5)
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
    }

    /// Game 2 of a doubleheader has no start time. Five minutes between
    /// checks left its card on "First pitch time TBD" well into the first
    /// inning when the socket was not delivering; 30s is hundreds of requests
    /// through game 1.
    func testAnUnknownStartIsCheckedEveryMinute() {
        XCTAssertEqual(
            PollSchedule.interval(inputs(.preGame(preGameInfo(firstPitch: nil)), now: now)), 60)
        XCTAssertEqual(
            PollSchedule.interval(inputs(.preGame(preGameInfo(firstPitch: nil)),
                                         pushIsHealthy: true, now: now)), 60)
    }

    func testLoadingRetriesSoon() {
        XCTAssertEqual(PollSchedule.interval(inputs(.loading)), 12)
    }

    // MARK: Cutting a sleep short

    /// The loop is 10s into a 60s sleep sized for a healthy socket when the
    /// card turns into something that wants checking every 5s.
    func testAShorterIntervalCutsTheSleepShort() {
        XCTAssertTrue(PollSchedule.shouldPollSooner(
            wanted: 5, sleepEnds: now.addingTimeInterval(50), now: now))
    }

    /// The reported waste: during a break the loop sleeps until the two
    /// minutes are up, and the interval the card "wants" is the same countdown
    /// read later — shorter than the sleep was, but ending at the same moment.
    /// Each socket update used to restart the loop and download the feed.
    func testTheBreakCountdownDoesNotRestartTheLoop() {
        let breakStart = now.addingTimeInterval(-40)
        // The loop went to sleep 40s into the break, for the 80s that were left.
        let sleepEnds = breakStart.addingTimeInterval(120)
        for elapsed in stride(from: 41.0, through: 119.0, by: 13.0) {
            let later = breakStart.addingTimeInterval(elapsed)
            let wanted = PollSchedule.interval(inputs(breakState(inning: 4),
                                                      pushIsHealthy: true,
                                                      betweenInningsStart: breakStart,
                                                      sawBreakStart: true,
                                                      now: later))
            XCTAssertFalse(
                PollSchedule.shouldPollSooner(wanted: wanted, sleepEnds: sleepEnds, now: later),
                "restarted \(elapsed)s into the break")
        }
    }

    /// Waking a few seconds early is not worth a download.
    func testASleepAboutToEndIsLeftAlone() {
        XCTAssertFalse(PollSchedule.shouldPollSooner(
            wanted: 5, sleepEnds: now.addingTimeInterval(3), now: now))
        XCTAssertFalse(PollSchedule.shouldPollSooner(
            wanted: 5, sleepEnds: now.addingTimeInterval(5.5), now: now))
    }

    func testALongerIntervalNeverCutsTheSleepShort() {
        XCTAssertFalse(PollSchedule.shouldPollSooner(
            wanted: 120, sleepEnds: now.addingTimeInterval(30), now: now))
        // A finished game wants no more polls at all.
        XCTAssertFalse(PollSchedule.shouldPollSooner(
            wanted: .infinity, sleepEnds: now.addingTimeInterval(30), now: now))
    }

    /// The socket drops while the loop is asleep on the 60s net: with push no
    /// longer healthy the live card wants 5s, and the loop must not wait out
    /// the rest of the minute.
    func testALostSocketCutsTheSleepShort() {
        let wanted = PollSchedule.interval(inputs(liveState(), pushIsHealthy: false))
        XCTAssertTrue(PollSchedule.shouldPollSooner(
            wanted: wanted, sleepEnds: now.addingTimeInterval(45), now: now))
    }

    private func preGameInfo(firstPitch: Date?) -> PreGameInfo {
        PreGameInfo(
            venueName: "Oracle Park", homeTeam: "SF", awayTeam: "LAD",
            firstPitch: firstPitch, homePitcher: nil, awayPitcher: nil,
            homeHand: nil, awayHand: nil
        )
    }
}
