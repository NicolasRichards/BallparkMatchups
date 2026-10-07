import Foundation

/// Whether a game can still continue, judged from the linescore alone.
///
/// MLB keeps reporting "In Progress" for a few seconds past the final out, so
/// the card has to work this out for itself or it shows a break for an inning
/// that is never coming. A game that ended 4–3 to the away team in the 10th
/// sat on "GDD coming to bat" for about two minutes.
enum GameCompletion {
    /// True when no further play is possible.
    ///
    /// - `"End"` — the bottom half is complete, so at the last scheduled
    ///   inning or beyond *either* team's lead ends the game. The earlier
    ///   version of this check only looked for a home lead, which is why an
    ///   away-team win in extras went unnoticed.
    /// - `"Middle"` — only a home lead ends it, because the home team does not
    ///   need to bat. An away lead still leaves the bottom half to play.
    /// - A tie ends nothing, and neither does anything before the last
    ///   scheduled inning.
    static func isOver(
        inning: Int,
        inningState: String,
        scheduledInnings: Int,
        homeRuns: Int,
        awayRuns: Int
    ) -> Bool {
        guard inning >= scheduledInnings else { return false }
        switch inningState {
        case "End":    return homeRuns != awayRuns
        case "Middle": return homeRuns > awayRuns
        default:       return false
        }
    }
}
