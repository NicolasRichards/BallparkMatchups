import Foundation

/// How large a sample a situational split needs before the card will show it.
///
/// The Fall League needs its own answer. Its season is about thirty games, so
/// a *career* there is a few dozen plate appearances at most — a live game a
/// week into the 2026 season returned a career-high of 17 PA, which the
/// ordinary 25 PA cutoff hid completely. The numbers are small by nature and
/// grow as the league goes on; that is the point of showing them.
enum SplitThresholds {
    static let career = 25
    static let season = 15
    /// Deliberately low. See above: anything higher shows nothing in October.
    static let fallLeagueCareer = 10

    static func minPA(isCareer: Bool, sportId: Int) -> Int {
        guard isCareer else { return season }
        return sportId == SportLevel.fallLeague.rawValue ? fallLeagueCareer : career
    }
}
