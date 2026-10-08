import XCTest
@testable import PatchCore

/// The Fall League gets a lower career cutoff than everywhere else.
///
/// A live game a week into the 2026 Fall League returned a career-high of
/// 17 PA — real data, scoped correctly to sportId 17, and hidden entirely by
/// the ordinary 25 PA cutoff. Ten lets a line through in October that grows
/// as the league goes on.
final class SplitThresholdsTests: XCTestCase {

    func testBothFallLeagueCutoffsAreTen() {
        for isCareer in [true, false] {
            XCTAssertEqual(
                SplitThresholds.minPA(isCareer: isCareer,
                                      sportId: SportLevel.fallLeague.rawValue), 10,
                "isCareer: \(isCareer)")
        }
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

    /// Every other league keeps 15 for the season.
    func testEveryOtherLeagueKeepsFifteenForTheSeason() {
        for level in [SportLevel.mlb, .aaa, .aa, .highA, .lowA] {
            XCTAssertEqual(
                SplitThresholds.minPA(isCareer: false, sportId: level.rawValue), 15,
                "\(level)")
        }
    }

    /// The 8 PA maximum seen five days into the 2026 Fall League is still
    /// below the cutoff, which is intended: ten asks for more than a handful
    /// of trips, and a line should appear within a few more games.
    func testAnEightPlateAppearanceSplitStillDoesNotShow() {
        XCTAssertGreaterThan(
            SplitThresholds.minPA(isCareer: false,
                                  sportId: SportLevel.fallLeague.rawValue), 8)
    }
}
