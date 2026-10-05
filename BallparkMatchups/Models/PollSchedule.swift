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
            return 300

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
            // The last out of the last scheduled inning looks exactly like any
            // other break, but no inning follows it, so the two-minute timer
            // below would sit on "END OF THE 9TH" until it expired. Keep
            // checking instead. Extra innings cost a few extra polls, which is
            // the right trade for showing the final promptly.
            if input.gameEndAnnounced || info.inning >= input.scheduledInnings { return 5 }
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

        case .final_, .postponed, .cancelled:
            return .infinity

        case .loading:
            return 12
        }
    }
}
