import Foundation

/// How long the poll loop waits before its next request.
///
/// This lives outside `GameViewModel` so the end-of-game behaviour can be
/// tested without a live feed. The bug it exists to prevent was reported on
/// three games running: the last out lands and the card sits on "END OF THE
/// 9TH" — never showing the third out, never showing the final. MLB keeps
/// reporting "In Progress" for a few seconds past the final out, and by then
/// the socket has closed, so the poll loop is the only thing left that can
/// notice. Every branch that backs off — the 60s net the socket allows, the
/// two-minute break timer — holds the stale card up for exactly that long.
enum PollSchedule {
    /// Everything the decision reads, gathered so the function stays pure.
    struct Inputs {
        /// What the card is currently showing.
        var state: GameUIState
        /// Whether patches are genuinely arriving on the socket.
        var pushIsHealthy: Bool
        /// The socket said the game is over. A one-way latch: once MLB has
        /// announced it, nothing clears it.
        var gameEndAnnounced: Bool
        /// 9 normally, 7 for the short games of a doubleheader. Read from the
        /// feed's `linescore.scheduledInnings` rather than assumed.
        var scheduledInnings: Int
        /// When the current half-inning break began, if one is underway.
        var betweenInningsStart: Date?
        /// Whether the break was watched from its start, as opposed to the
        /// card being opened into one already in progress.
        var sawBreakStart: Bool
        /// Injected so the break timer is testable.
        var now: Date = Date()
        /// The card shows a "Game Over" final whose W/L/SV decisions MLB
        /// publishes only at "Final", so keep checking for them.
        var awaitingDecisions = false
    }

    /// The seconds to wait. `.infinity` means the game is over and the loop
    /// should stop rather than sleep.
    static func interval(_ input: Inputs) -> TimeInterval {
        switch input.state {
        case .preGame(let info):
            if let fp = info.firstPitch {
                let mins = fp.timeIntervalSince(input.now) / 60
                return mins < 15 ? 30 : 300
            }
            // No start time: game 2 of a doubleheader begins whenever game 1
            // lets it. Every 30s is hundreds of requests through game 1, and
            // every 5 minutes left the card on "First pitch time TBD" for up
            // to five minutes after play began whenever the socket was not
            // there to say so. A minute bounds both.
            return 60

        case .live:
            // Once the socket has said the game is over it has also closed, so
            // the poll loop is the only thing left that can notice the switch
            // to Final. Backing off to the 60s net here leaves a stale matchup
            // up for most of a minute.
            if input.gameEndAnnounced { return 5 }
            // The socket is the fast path when it is up; this is only a net for
            // events it drops, so it does not need to be tight.
            return input.pushIsHealthy ? 60 : 5

        case .betweenInnings(let info):
            if input.gameEndAnnounced { return 5 }
            // The last out of the last scheduled inning looks exactly like any
            // other break, but no inning follows it, so the two-minute timer
            // below would sit on "END OF THE 9TH" until it expired. Keep
            // checking instead — when there is no socket to say the game is
            // over. While patches are arriving the socket announces the end,
            // and `GameCompletion` has already read the linescore and found
            // the game still on, so checking every 5s only re-downloads the
            // whole feed two dozen times through a break that leads to more
            // baseball.
            if info.inning >= input.scheduledInnings, !input.pushIsHealthy { return 5 }
            // Wait ~2 minutes from when the inning ended, then switch to 5s
            // so we catch the first pitch of the new half-inning quickly.
            if let start = input.betweenInningsStart {
                // Opened mid-break: the break may be nearly over, so check often
                guard input.sawBreakStart else { return 20 }
                let remaining = 120 - input.now.timeIntervalSince(start)
                return remaining > 5 ? remaining : 5
            }
            return 120

        case .delay, .suspended:
            return input.gameEndAnnounced ? 5 : 60

        case .final_:
            return input.awaitingDecisions ? 30 : .infinity

        case .postponed, .cancelled:
            return .infinity

        case .loading:
            return 12
        }
    }

    /// Whether the loop should give up the sleep it is in and check now.
    ///
    /// Asked when the socket changes the card, or drops, in the middle of a
    /// sleep. The comparison is against when that sleep *ends*, not how long
    /// it was. A half-inning break's interval is a countdown, so it is always
    /// shorter than it was when the loop went to sleep; comparing lengths
    /// restarted the loop — a download of the whole feed — on every update
    /// the socket delivered during a break.
    static func shouldPollSooner(
        wanted: TimeInterval,
        sleepEnds: Date,
        now: Date = Date()
    ) -> Bool {
        guard wanted.isFinite else { return false }
        // A second of slack: the two sides come from clocks read a moment
        // apart, and waking a second early is not worth a download.
        return now.addingTimeInterval(wanted) < sleepEnds.addingTimeInterval(-1)
    }
}
