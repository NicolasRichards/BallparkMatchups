import Foundation

// MARK: - Venue List Response

struct VenueListResponse: Codable {
    let venues: [VenueDetail]

    struct VenueDetail: Codable {
        let id: Int
        let name: String
        let active: Bool?
        let location: Location?
        let timeZone: TimeZoneInfo?

        struct Location: Codable {
            let defaultCoordinates: Coordinates?

            struct Coordinates: Codable {
                let latitude: Double
                let longitude: Double
            }
        }

        struct TimeZoneInfo: Codable {
            let id: String
        }
    }
}

// MARK: - Schedule Response

struct ScheduleResponse: Codable {
    let dates: [ScheduleDate]

    struct ScheduleDate: Codable {
        let date: String
        let games: [ScheduleGame]
    }

    struct ScheduleGame: Codable {
        let gamePk: Int
        let gameType: String
        let status: GameStatus
        let teams: GameTeams
        let venue: VenueRef
        let gameDate: String
        let linescore: LinescoreBasic?
        let seriesDescription: String?

        struct GameStatus: Codable {
            let detailedState: String
            let statusCode: String?
        }

        struct GameTeams: Codable {
            let home: TeamEntry
            let away: TeamEntry

            struct TeamEntry: Codable {
                let team: TeamInfo
                let score: Int?
                let probablePitcher: PlayerRef?

                struct TeamInfo: Codable {
                    let id: Int
                    let name: String
                    let abbreviation: String?
                    let sport: SportRef?

                    struct SportRef: Codable {
                        let id: Int
                    }
                }
            }
        }

        struct VenueRef: Codable {
            let id: Int
            let name: String?
        }

        struct LinescoreBasic: Codable {
            let currentInning: Int?
            let inningState: String?
        }
    }
}

// MARK: - Live Feed (GUMBO) Response

struct LiveFeedResponse: Codable {
    let metaData: MetaData
    let gameData: GameData
    let liveData: LiveData?

    struct MetaData: Codable {
        let timeStamp: String  // "20240515_193045"
    }

    struct GameData: Codable {
        let status: GameStatus
        let datetime: GameDatetime?
        let teams: GameTeams
        let venue: VenueRef?
        let probablePitchers: ProbablePitchers?

        struct GameStatus: Codable {
            let detailedState: String
            let statusCode: String?
        }

        struct GameDatetime: Codable {
            let dateTime: String?
            let originalDate: String?
        }

        // In GUMBO, gameData.teams.home IS the team object directly (no nested "team" key)
        struct GameTeams: Codable {
            let home: GameTeamEntry
            let away: GameTeamEntry

            struct GameTeamEntry: Codable {
                let id: Int
                let name: String
                let abbreviation: String?
                let sport: SportRef?

                struct SportRef: Codable {
                    let id: Int
                }
            }
        }

        struct ProbablePitchers: Codable {
            let home: PlayerRef?
            let away: PlayerRef?
        }

        struct VenueRef: Codable {
            let id: Int
            let name: String?
        }
    }

    struct LiveData: Codable {
        let plays: Plays?
        let linescore: Linescore?
        let boxscore: Boxscore?
        let decisions: Decisions?

        struct Plays: Codable {
            let currentPlay: CurrentPlay?

            struct CurrentPlay: Codable {
                let atBatIndex: Int
                let matchup: Matchup?
                let count: Count?

                struct Matchup: Codable {
                    let batter: PlayerRef?
                    let pitcher: PlayerRef?
                    let batSide: HandCode?
                    let pitchHand: HandCode?

                    struct HandCode: Codable {
                        let code: String
                    }
                }

                struct Count: Codable {
                    let balls: Int
                    let strikes: Int
                    let outs: Int
                }
            }
        }

        struct Linescore: Codable {
            let currentInning: Int?
            let currentInningOrdinal: String?
            let inningState: String?
            let offense: Offense?
            let defense: Defense?
            let balls: Int?
            let strikes: Int?
            let outs: Int?
            let teams: LinescoreTeams?

            struct Offense: Codable {
                let batter: PlayerRef?
                let onFirst: PlayerRef?
                let onSecond: PlayerRef?
                let onThird: PlayerRef?

                enum CodingKeys: String, CodingKey {
                    case batter
                    case onFirst  = "first"
                    case onSecond = "second"
                    case onThird  = "third"
                }
            }

            struct Defense: Codable {
                let pitcher: PlayerRef?
                let catcher: PlayerRef?
            }

            struct LinescoreTeams: Codable {
                let home: TeamScore
                let away: TeamScore

                struct TeamScore: Codable {
                    let runs: Int?
                    let hits: Int?
                    let errors: Int?
                }
            }
        }

        struct Boxscore: Codable {
            let teams: BoxscoreTeams?

            struct BoxscoreTeams: Codable {
                let home: TeamBox?
                let away: TeamBox?

                struct TeamBox: Codable {
                    let pitchers: [Int]?
                    let players: [String: BoxPlayer]?

                    struct BoxPlayer: Codable {
                        let person: PlayerRef?
                        let stats: BoxStats?
                        let gameStatus: GameStatus?

                        struct BoxStats: Codable {
                            let batting: BattingStats?
                            let pitching: PitchingStats?

                            struct BattingStats: Codable {
                                let atBats: Int?
                                let hits: Int?
                                let rbi: Int?
                            }

                            struct PitchingStats: Codable {
                                let numberOfPitches: Int?
                                let strikes: Int?
                                let inningsPitched: String?
                                let strikeOuts: Int?
                                let earnedRuns: Int?
                            }
                        }

                        struct GameStatus: Codable {
                            let isCurrentPitcher: Bool?
                        }
                    }
                }
            }
        }

        struct Decisions: Codable {
            let winner: PlayerRef?
            let loser: PlayerRef?
            let save: PlayerRef?
        }
    }
}

// MARK: - Stats Response (BvP + Splits)

struct StatsResponse: Codable {
    let stats: [StatGroup]

    struct StatGroup: Codable {
        let type: StatType?
        let splits: [SplitEntry]

        struct StatType: Codable {
            let displayName: String?
        }

        struct SplitEntry: Codable {
            let split: SplitInfo?
            let stat: StatLine
            let season: String?

            struct SplitInfo: Codable {
                let code: String
                let description: String?
            }

            struct StatLine: Codable {
                let plateAppearances: Int?
                let atBats: Int?
                let hits: Int?
                let avg: String?
                let obp: String?
                let slg: String?
                let ops: String?
                let homeRuns: Int?
                let strikeOuts: Int?
                let baseOnBalls: Int?
            }
        }
    }
}

// MARK: - Player Response

struct PlayerResponse: Codable {
    let people: [PersonDetail]

    struct PersonDetail: Codable {
        let id: Int
        let fullName: String
        let primaryPosition: Position?
        let batSide: HandCode?
        let pitchHand: HandCode?
        let height: String?     // "6' 2\""
        let weight: Int?
        let birthDate: String?  // "1996-10-24"
        let currentTeam: TeamRef?

        struct Position: Codable {
            let code: String
            let abbreviation: String?
        }

        struct HandCode: Codable {
            let code: String
        }

        struct TeamRef: Codable {
            let id: Int
            let name: String?
            let abbreviation: String?
        }
    }
}

// MARK: - Shared

struct PlayerRef: Codable {
    let id: Int
    let fullName: String?
}
