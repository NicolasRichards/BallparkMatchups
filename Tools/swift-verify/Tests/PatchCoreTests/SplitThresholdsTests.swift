import XCTest
@testable import PatchCore

/// The Fall League gets a lower career cutoff than everywhere else.
///
/// A live game a week into the 2026 Fall League returned a career-high of
/// 17 PA — real data, scoped correctly to sportId 17, and hidden entirely by
/// the ordinary 25 PA cutoff. Ten lets a line through in October that grows
/// as the league goes on.
final class SplitThresholdsTests: XCTestCase {

    func testTheFallLeagueCareerCutoffIsTen() {
        XCTAssertEqual(
            SplitThresholds.minPA(isCareer: true,
                                  sportId: SportLevel.fallLeague.rawValue), 10)
    }

    /// The 17 PA sample that prompted this would now show.
    func testTheSampleThatPromptedThisWouldNowShow() {
        let cutoff = SplitThresholds.minPA(isCareer: true,
                                           sportId: SportLevel.fallLeague.rawValue)
        XCTAssertLessThanOrEqual(cutoff, 17)
    }

    /// Every other league keeps 25. A ten-plate-appearance career line means
    /// nothing for a major leaguer, and the change was asked for the Fall
    /// League specifically.
    func testEveryOtherLeagueKeepsTwentyFive() {
        for level in [SportLevel.mlb, .aaa, .aa, .highA, .lowA] {
            XCTAssertEqual(
                SplitThresholds.minPA(isCareer: true, sportId: level.rawValue), 25,
                "\(level)")
        }
    }

    /// The season cutoff is untouched, in every league including the Fall
    /// League — only the career one was asked about.
    func testTheSeasonCutoffIsFifteenEverywhere() {
        for level in [SportLevel.mlb, .aaa, .aa, .highA, .lowA, .fallLeague] {
            XCTAssertEqual(
                SplitThresholds.minPA(isCareer: false, sportId: level.rawValue), 15,
                "\(level)")
        }
    }
}
