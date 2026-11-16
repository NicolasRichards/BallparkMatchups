import Foundation

// A stand-in for the app's MLBAPIClient with the same surface, serving scripted
// feeds and canned stats, and failing on request. Everything else in the
// simulator is the app's real source.

enum APIError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case decodingError(DecodingError)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .networkError(let e): return e.localizedDescription
        case .decodingError: return "Data parse error"
        case .httpError(let code): return "Server error \(code)"
        }
    }
}

actor MLBAPIClient {
    static let shared = MLBAPIClient()

    struct RawResponse: Sendable {
        let value: JSONValue
        let byteCount: Int
    }

    enum Failure: Error, Sendable {
        case always
        case times(Int)
        /// Fails like a dead network rather than a server answering badly.
        case offline
    }

    struct Hit: Sendable {
        let at: Date
        let key: String
    }

    private var feeds: [Int: [Data]] = [:]
    private var feedCalls: [Int: Int] = [:]
    /// When set, every feed request for the game gets this document.
    private var pinned: [Int: Data] = [:]
    private var latency: [String: UInt64] = [:]
    private var failures: [String: Failure] = [:]
    private var emptyKeys: Set<String> = []
    private var log: [Hit] = []
    private var diffQueue: [Int: [Result<Data, Failure>]] = [:]

    // MARK: Scripting

    func script(gamePk: Int, feeds: [Data]) {
        self.feeds[gamePk] = feeds
        feedCalls[gamePk] = 0
    }

    func setFailure(_ key: String, _ failure: Failure?) {
        failures[key] = failure
    }

    func pin(gamePk: Int, feed: Data) { pinned[gamePk] = feed }

    func setLatency(_ key: String, seconds: Double) { latency[key] = UInt64(seconds * 1_000_000_000) }

    /// Makes a stats request succeed with no rows.
    func setEmpty(_ key: String) { emptyKeys.insert(key) }

    func hits(_ prefix: String) -> [Hit] { log.filter { $0.key.hasPrefix(prefix) } }

    func feedCallCount(_ gamePk: Int) -> Int { feedCalls[gamePk] ?? 0 }

    /// Queues the answers diffPatch will give, in order.
    func queueDiffs(gamePk: Int, _ answers: [Result<Data, Failure>]) {
        diffQueue[gamePk, default: []].append(contentsOf: answers)
    }

    private func hit(_ key: String) async throws {
        log.append(Hit(at: Date(), key: key))
        try? await Task.sleep(nanoseconds: latency[key] ?? 40_000_000)   // a little latency
        try Task.checkCancellation()
        guard let failure = failures[key] else { return }
        switch failure {
        case .always:
            throw APIError.httpError(503)
        case .offline:
            throw APIError.networkError(URLError(.notConnectedToInternet))
        case .times(let n):
            failures[key] = n > 1 ? .times(n - 1) : nil
            throw APIError.httpError(503)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Live feed

    func fetchLiveFeed(gamePk: Int) async throws -> LiveFeedResponse {
        try await hit("feed:\(gamePk)")
        if let data = pinned[gamePk] { return try JSONDecoder().decode(LiveFeedResponse.self, from: data) }
        guard let list = feeds[gamePk], !list.isEmpty else { throw APIError.httpError(404) }
        let i = feedCalls[gamePk] ?? 0
        feedCalls[gamePk] = i + 1
        return try JSONDecoder().decode(LiveFeedResponse.self, from: list[min(i, list.count - 1)])
    }

    func fetchLiveFeedRaw(gamePk: Int, pushUpdateId: String? = nil) async throws -> RawResponse {
        try await hit("feedRaw:\(gamePk)")
        if let data = pinned[gamePk] { return RawResponse(value: try JSONValue.parse(data), byteCount: data.count) }
        guard let list = feeds[gamePk], !list.isEmpty else { throw APIError.httpError(404) }
        let i = feedCalls[gamePk] ?? 0
        feedCalls[gamePk] = i + 1
        let data = list[min(i, list.count - 1)]
        return RawResponse(value: try JSONValue.parse(data), byteCount: data.count)
    }

    func fetchDiffPatch(gamePk: Int, startTimecode: String, pushUpdateId: String) async throws -> RawResponse {
        log.append(Hit(at: Date(), key: "diff:\(gamePk)"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard var queue = diffQueue[gamePk], !queue.isEmpty else {
            return RawResponse(value: .array([]), byteCount: 2)
        }
        let next = queue.removeFirst()
        diffQueue[gamePk] = queue
        switch next {
        case .success(let data):
            return RawResponse(value: try JSONValue.parse(data), byteCount: data.count)
        case .failure(.offline):
            throw APIError.networkError(URLError(.notConnectedToInternet))
        case .failure:
            throw APIError.httpError(503)
        }
    }

    // MARK: Players and stats

    func fetchPlayer(id: Int) async throws -> PlayerResponse {
        try await hit("player:\(id)")
        return try decode(PlayerResponse.self, #"{"people":[{"id":\#(id),"fullName":"Looked Up \#(id)"}]}"#)
    }

    func fetchBvP(batterId: Int, pitcherId: Int, sportId: Int) async throws -> StatsResponse {
        let key = "bvp:\(batterId)"
        try await hit(key)
        if emptyKeys.contains(key) { return try decode(StatsResponse.self, #"{"stats":[]}"#) }
        return try decode(StatsResponse.self, """
        {"stats":[{"type":{"displayName":"vsPlayer"},"splits":[{"season":"2025","stat":{"plateAppearances":3,"atBats":3,"hits":0,"avg":".000","obp":".000","slg":".000","ops":".000"}}]},
                  {"type":{"displayName":"vsPlayerTotal"},"splits":[{"stat":{"plateAppearances":12,"atBats":10,"hits":3,"avg":".300","obp":".417","slg":".500","ops":".917","homeRuns":1,"strikeOuts":2,"baseOnBalls":2}}]}]}
        """)
    }

    func fetchSeasonHitting(playerId: Int, season: Int, sportId: Int) async throws -> StatsResponse {
        try await hit("seasonLine:\(playerId)")
        return try decode(StatsResponse.self, #"{"stats":[{"splits":[{"stat":{"plateAppearances":500,"ops":".800"}}]}]}"#)
    }

    func fetchCareerHitting(playerId: Int, sportId: Int) async throws -> StatsResponse {
        try await hit("careerLine:\(playerId)")
        return try decode(StatsResponse.self, #"{"stats":[{"splits":[{"stat":{"plateAppearances":2500,"ops":".780"}}]}]}"#)
    }

    func fetchCareerSplits(playerId: Int, sitCodes: [String], group: String, sportId: Int) async throws -> StatsResponse {
        let key = "careerSplits:\(group):\(playerId)"
        try await hit(key)
        if emptyKeys.contains(key) { return try decode(StatsResponse.self, #"{"stats":[]}"#) }
        return try decode(StatsResponse.self, splitsJSON(sitCodes, group: group, ops: ".930", pa: 900))
    }

    func fetchSplits(playerId: Int, sitCodes: [String], group: String = "hitting", season: Int? = nil, sportId: Int) async throws -> StatsResponse {
        let key = "splits:\(group):\(playerId)"
        try await hit(key)
        if emptyKeys.contains(key) { return try decode(StatsResponse.self, #"{"stats":[]}"#) }
        return try decode(StatsResponse.self, splitsJSON(sitCodes, group: group, ops: ".950", pa: 200))
    }

    private func splitsJSON(_ codes: [String], group: String, ops: String, pa: Int) -> String {
        let paKey = group == "pitching" ? "battersFaced" : "plateAppearances"
        let rows = codes.map {
            #"{"split":{"code":"\#($0)"},"stat":{"\#(paKey)":\#(pa),"avg":".310","obp":".400","slg":".550","ops":"\#(ops)"}}"#
        }
        return #"{"stats":[{"splits":[\#(rows.joined(separator: ","))]}]}"#
    }
}
