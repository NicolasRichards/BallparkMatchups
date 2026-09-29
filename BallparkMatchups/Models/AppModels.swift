import Foundation

// MARK: - Enums

enum SportLevel: Int, CaseIterable {
    case mlb = 1, aaa = 11, aa = 12, highA = 13, lowA = 14

    var displayName: String {
        switch self {
        case .mlb: return "MLB"
        case .aaa: return "AAA"
        case .aa: return "AA"
        case .highA: return "High-A"
        case .lowA: return "Low-A"
        }
    }
}

enum Handedness: String {
    case left = "L", right = "R", switchHitter = "S"

    var displayCode: String { rawValue }
}

enum RunnersState: String {
    case empty = "___"
    case first = "1__"
    case second = "_2_"
    case third = "__3"
    case firstSecond = "12_"
    case firstThird = "1_3"
    case secondThird = "_23"
    case loaded = "123"

    var hasScoringPosition: Bool {
        switch self {
        case .second, .third, .firstSecond, .firstThird, .secondThird, .loaded: return true
        default: return false
        }
    }

    var hasRunners: Bool { self != .empty }

    var isLoaded: Bool { self == .loaded }

    var hasThirdLessThanTwo: Bool {
        switch self {
        case .third, .firstThird, .secondThird, .loaded: return true
        default: return false
        }
    }

    static func from(onFirst: Bool, onSecond: Bool, onThird: Bool) -> RunnersState {
        switch (onFirst, onSecond, onThird) {
        case (false, false, false): return .empty
        case (true, false, false): return .first
        case (false, true, false): return .second
        case (false, false, true): return .third
        case (true, true, false): return .firstSecond
        case (true, false, true): return .firstThird
        case (false, true, true): return .secondThird
        case (true, true, true): return .loaded
        }
    }
}

// MARK: - Player

struct PlayerInfo {
    let id: Int
    let fullName: String
    let primaryPosition: String   // "3B", "RHP", "LHP", etc.
    let batSide: Handedness?
    let pitchHand: Handedness?
    let heightFeet: Int?
    let heightInches: Int?
    let weightLbs: Int?
    let birthDate: Date?
    let teamAbbreviation: String?

    var ageString: String? {
        guard let bd = birthDate else { return nil }
        let years = Calendar.current.dateComponents([.year], from: bd, to: Date()).year
        return years.map { "\($0) yrs" }
    }

    var heightString: String? {
        guard let ft = heightFeet, let inches = heightInches else { return nil }
        return "\(ft)'\(inches)\""
    }
}

// MARK: - Stats

struct BvPLine {
    let pa: Int
    let atBats: Int
    let hits: Int
    let avg: String
    let obp: String
    let slg: String
    let ops: Double?   // parsed for info-gain filter
    let hr: Int
    let so: Int
    let bb: Int

    // Raw hit line used when PA is small. Built from the real counts:
    // deriving hits from avg × PA truncated 1-for-3 (.333 × 3) to 0 and
    // divided by PA, not AB, when there were walks.
    var rawLine: String {
        var parts = ["\(hits)-for-\(atBats)"]
        if hr > 0 { parts.append("\(hr) HR") }
        if bb > 0 { parts.append("\(bb) BB") }
        return parts.joined(separator: ", ")
    }
}

struct SplitLine {
    let sitCode: String
    let label: String       // "RISP, 2 OUT"
    let scope: String       // "career" or "2026"
    let pa: Int
    let avg: String
    let obp: String
    let slg: String
    let ops: Double         // for info-gain filter
}

// MARK: - Situation

struct SituationStrip {
    let inning: Int
    let inningState: String  // "Top", "Bottom", "Middle", "End"
    let outs: Int
    let runners: RunnersState
    let balls: Int
    let strikes: Int

    var displayInning: String {
        let arrow = (inningState == "Top" || inningState == "Middle") ? "▲" : "▼"
        return "\(arrow)\(inning)"
    }

    var outsDisplay: String { "\(outs) out\(outs == 1 ? "" : "s")" }

    var runnersDisplay: String {
        switch runners {
        case .empty: return "Bases empty"
        case .first: return "Runner on 1st"
        case .second: return "Runner on 2nd"
        case .third: return "Runner on 3rd"
        case .firstSecond: return "1st & 2nd"
        case .firstThird: return "1st & 3rd"
        case .secondThird: return "2nd & 3rd"
        case .loaded: return "Bases loaded"
        }
    }

    var countDisplay: String { "\(balls)-\(strikes)" }
}

// MARK: - Game Lines

struct BatterGameLine {
    let atBats: Int
    let hits: Int
    let rbi: Int

    var display: String {
        var parts = ["\(hits)-\(atBats)"]
        if rbi > 0 { parts.append("\(rbi) RBI") }
        return parts.joined(separator: ", ")
    }
}

struct PitcherGameLine {
    let pitches: Int
    let strikes: Int
    let inningsPitched: String  // e.g. "0.1", "3.0"
    let strikeOuts: Int
    let earnedRuns: Int

    var pitchLine: String { "\(pitches) P · \(strikes) S" }
    var statLine: String { "\(inningsPitched) IP, \(strikeOuts) K, \(earnedRuns) ER" }
}

// MARK: - Score Display

struct ScoreDisplay {
    let awayAbbr: String
    let awayScore: Int
    let homeAbbr: String
    let homeScore: Int
}

// MARK: - Matchup Card

struct MatchupCard {
    let batter: PlayerInfo
    let pitcher: PlayerInfo
    let situation: SituationStrip
    let bvp: BvPLine?
    let batterSplits: [SplitLine]   // batter situational splits, max 3
    let pitcherSplit: SplitLine?    // single pitcher split, distinct sitCode from batter splits
    let batterGame: BatterGameLine?
    let pitcherGame: PitcherGameLine?
    let lastEvent: String?          // result.description of the last completed at-bat
}

// MARK: - Polling Diff

struct TickState: Equatable {
    let atBatIndex: Int
    let batterId: Int
    let pitcherId: Int
    let balls: Int
    let strikes: Int
    let outs: Int
    let runnersCode: String  // e.g. "_23"
    let inningState: String  // "Top", "Middle", "Bottom", "End"
    let halfInning: Int
}

enum RefreshKind {
    case none, countOnly, situational, full
}

func diffTickState(old: TickState?, new: TickState) -> RefreshKind {
    guard let old else { return .full }
    if new.atBatIndex != old.atBatIndex { return .full }
    if new.batterId != old.batterId { return .full }   // mid-AB pinch hitter
    if new.pitcherId != old.pitcherId { return .full }
    if new.outs != old.outs || new.runnersCode != old.runnersCode { return .situational }
    if new.balls != old.balls || new.strikes != old.strikes { return .countOnly }
    return .none
}

// MARK: - Venue

struct CachedVenue: Codable {
    let id: Int
    let name: String
    let teamName: String?
    let latitude: Double
    let longitude: Double
    let timeZoneIdentifier: String
    let sportId: Int

    var sportLevel: SportLevel? { SportLevel(rawValue: sportId) }
}

// MARK: - Game Session Persistence

struct ActiveSession: Codable {
    let gamePk: Int
    let venueId: Int?
    let resolvedAt: Date
    var lastKnownState: String?
}

// MARK: - Game List (Browse)

struct GameSummary: Identifiable {
    let id: Int  // gamePk
    let gamePk: Int
    let homeTeam: String
    let awayTeam: String
    let homeAbbr: String
    let awayAbbr: String
    let homeScore: Int?
    let awayScore: Int?
    let detailedState: String
    let gameDate: Date
    let venueId: Int
    let venueName: String
    let sportId: Int
    let currentInning: Int?
    let inningState: String?
    /// From the schedule's status; see ScheduleGame.GameStatus.
    let isUnderway: Bool
    let isOver: Bool

    var sportLevel: SportLevel? { SportLevel(rawValue: sportId) }
    var isMiLB: Bool { sportId != 1 }

    var bucketLabel: String {
        if isUnderway { return "LIVE NOW" }
        if isOver { return "FINAL" }
        // Not started yet. Past its start time means it is late (a delayed
        // start, a long warmup) — still coming, not over.
        let diff = gameDate.timeIntervalSince(Date())
        return diff <= 7200 ? "STARTING SOON" : "LATER TODAY"
    }

    var scoreDisplay: String? {
        guard let h = homeScore, let a = awayScore else { return nil }
        return "\(awayAbbr) \(a), \(homeAbbr) \(h)"
    }

    var statusDisplay: String {
        if detailedState == "In Progress", let inn = currentInning, let state = inningState {
            let arrow = (state == "Top" || state == "Middle") ? "▲" : "▼"
            return "\(arrow)\(inn)"
        }
        return detailedState
    }
}

// MARK: - Error handling

enum ConnectionStatus {
    case ok
    case retrying(lastUpdated: Date, failures: Int)
    case degraded(since: Date)
}

// MARK: - App UI State

enum AppState {
    case loading            // brief splash while venue cache + session restore runs
    case entry
    case locating
    case browseGames
    case loadingGame(gamePk: Int)
    case game
    case locationDenied
    case locationFailed
    case notAtBallpark
    /// Location matched a ballpark but its schedule couldn't be loaded.
    case scheduleFailed(CachedVenue)
}
