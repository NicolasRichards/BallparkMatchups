import Foundation

// MARK: - Game UI State

enum GameUIState {
    case loading
    case preGame(PreGameInfo)
    case live(MatchupCard)
    case betweenInnings(BetweenInningsInfo)
    case delay(DelayInfo)
    case suspended
    case final_(FinalInfo)
    case postponed(String)
    case cancelled(String)
}

struct PreGameInfo {
    let venueName: String
    let homeTeam: String
    let awayTeam: String
    let firstPitch: Date?
    let homePitcher: String?
    let awayPitcher: String?
    let homeHand: String?
    let awayHand: String?
}

struct BetweenInningsInfo {
    let inning: Int
    let inningState: String   // "End" or "Middle"
    let nextTeam: String      // team about to bat
    let venueName: String
}

struct DelayInfo {
    let reason: String        // from detailedState
    let isPreGame: Bool
}

struct FinalInfo {
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int
    let awayScore: Int
    let winnerName: String?
    let winnerRecord: String?
    let loserName: String?
    let loserRecord: String?
    let saveName: String?
}
