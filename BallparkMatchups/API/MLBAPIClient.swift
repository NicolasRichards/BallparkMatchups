import Foundation

actor MLBAPIClient {
    static let shared = MLBAPIClient()

    private let baseURL = "https://statsapi.mlb.com"
    private let session: URLSession
    private var liveFeedTimecode: String?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Venues

    func fetchVenues(season: Int = Calendar.current.component(.year, from: Date())) async throws -> VenueListResponse {
        let url = "\(baseURL)/api/v1/venues?sportIds=1,11,12,13,14&hydrate=location,timezone&season=\(season)"
        return try await fetch(VenueListResponse.self, from: url)
    }

    // MARK: - Schedule

    func fetchSchedule(date: String, venueId: Int? = nil) async throws -> ScheduleResponse {
        var url = "\(baseURL)/api/v1/schedule?sportId=1,11,12,13,14&date=\(date)&hydrate=probablePitcher,team,linescore&gameTypes=R,F,D,L,W"
        if let id = venueId {
            url += "&venueIds=\(id)"
        }
        return try await fetch(ScheduleResponse.self, from: url)
    }

    // MARK: - Live Feed (GUMBO)

    func fetchLiveFeed(gamePk: Int, useTimecode: Bool = false) async throws -> LiveFeedResponse {
        var url = "\(baseURL)/api/v1.1/game/\(gamePk)/feed/live"
        if useTimecode, let tc = liveFeedTimecode {
            url += "?timecode=\(tc)"
        }
        let response = try await fetch(LiveFeedResponse.self, from: url)
        liveFeedTimecode = response.metaData.timeStamp
        return response
    }

    func resetTimecode() {
        liveFeedTimecode = nil
    }

    // MARK: - BvP Stats

    func fetchBvP(batterId: Int, pitcherId: Int) async throws -> StatsResponse {
        let url = "\(baseURL)/api/v1/people/\(batterId)/stats?stats=vsPlayer&opposingPlayerId=\(pitcherId)&group=hitting"
        return try await fetch(StatsResponse.self, from: url)
    }

    // MARK: - Situational Splits

    func fetchSplits(playerId: Int, sitCodes: [String], group: String = "hitting", season: Int? = nil) async throws -> StatsResponse {
        let codes = sitCodes.joined(separator: ",")
        var url = "\(baseURL)/api/v1/people/\(playerId)/stats?stats=statSplits&sitCodes=\(codes)&group=\(group)"
        if let s = season {
            url += "&season=\(s)"
        }
        return try await fetch(StatsResponse.self, from: url)
    }

    // MARK: - Player Metadata

    func fetchPlayer(id: Int) async throws -> PlayerResponse {
        let url = "\(baseURL)/api/v1/people/\(id)?hydrate=currentTeam"
        return try await fetch(PlayerResponse.self, from: url)
    }

    // MARK: - Batch Players

    func fetchPlayers(ids: [Int]) async throws -> PlayerResponse {
        let idString = ids.map { String($0) }.joined(separator: ",")
        let url = "\(baseURL)/api/v1/people?personIds=\(idString)&hydrate=currentTeam"
        return try await fetch(PlayerResponse.self, from: url)
    }

    // MARK: - Next Home Game

    func fetchNextHomeGame(venueId: Int, teamId: Int) async throws -> ScheduleResponse {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        let startDate = formatter.string(from: Date())
        let endDate: String = {
            let future = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
            return formatter.string(from: future)
        }()
        let url = "\(baseURL)/api/v1/schedule?sportId=1,11,12,13,14&teamId=\(teamId)&startDate=\(startDate)&endDate=\(endDate)&venueIds=\(venueId)&hydrate=team&gameTypes=R,F,D,L,W"
        return try await fetch(ScheduleResponse.self, from: url)
    }

    // MARK: - Private

    private func fetch<T: Decodable>(_ type: T.Type, from urlString: String) async throws -> T {
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else {
            throw APIError.invalidURL(urlString)
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw APIError.httpError(http.statusCode)
            }
            let decoder = JSONDecoder()
            return try decoder.decode(type, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }
}

// MARK: - Error

enum APIError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case decodingError(DecodingError)
    case httpError(Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .networkError(let e): return e.localizedDescription
        case .decodingError: return "Data parse error"
        case .httpError(let code): return "Server error \(code)"
        case .noData: return "No data"
        }
    }
}

// MARK: - Helpers

extension ScheduleResponse {
    var allGames: [ScheduleGame] {
        dates.flatMap(\.games)
    }

    var validGames: [ScheduleGame] {
        let validTypes = Set(["R", "F", "D", "L", "W"])
        return allGames.filter { validTypes.contains($0.gameType) }
    }
}
