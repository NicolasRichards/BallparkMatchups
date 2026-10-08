import Foundation

/// How large a sample a situational split needs before the card will show it.
///
/// The Fall League needs its own answer, and the same one for season and
/// career. Its season is about thirty games, and the cutoff applies to each
/// *split* rather than to the player's total: a batter showing 8 PA against
/// left-handers has perhaps 25 overall. A regular might reach 120 plate
/// appearances by mid-November, which puts the common splits somewhere around
/// 30 to 40 for the whole league season and the narrow ones well below that.
///
/// Against that ceiling the ordinary 25 and 15 are far too high — a live game
/// five days into the 2026 season returned a maximum of 8 PA, and nothing
/// showed at all. Ten is low enough to put a line up within a few games and
/// still ask for more than a handful of trips. For a player in his first Fall
/// League the season and career numbers are the same thing anyway, so there
/// is no reason to hold them to different standards.
enum SplitThresholds {
    static let career = 25
    static let season = 15
    /// Both season and career, deliberately low. See above.
    static let fallLeague = 10

    static func minPA(isCareer: Bool, sportId: Int) -> Int {
        if sportId == SportLevel.fallLeague.rawValue { return fallLeague }
        return isCareer ? career : season
    }
}
