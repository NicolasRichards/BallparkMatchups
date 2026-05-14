import Foundation
import Combine

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

// MARK: - GameViewModel

@MainActor
final class GameViewModel: ObservableObject {
    let gamePk: Int
    let venueName: String

    @Published var uiState: GameUIState = .loading
    @Published var connectionStatus: ConnectionStatus = .ok
    @Published var lastUpdated: Date?

    // Debug overlay data
    @Published var debugInfo: DebugInfo = DebugInfo()

    private var pollingTask: Task<Void, Never>?
    private var lastTickState: TickState?
    private var consecutiveFailures = 0
    private var requestCount = 0
    private var isFirstPoll = true

    // In-memory caches
    private var playerCache: [Int: PlayerInfo] = [:]
    private var careerSplitCache: [CacheKey: [SplitLine]] = [:]
    private var careerBvPCache: [BvPKey: BvPLine?] = [:]
    private var pitcherFirstAtBat: [Int: Int] = [:]  // pitcherId -> first atBatIndex

    private let api = MLBAPIClient.shared

    struct DebugInfo {
        var pollingInterval: TimeInterval = 12
        var lastResponseTime: Date?
        var requestCount: Int = 0
        var candidateSplits: Int = 0
        var shownSplits: Int = 0
        var lastRefreshKind: String = "-"
    }

    struct CacheKey: Hashable {
        let playerId: Int
        let sitCode: String
        let isCareer: Bool
    }

    struct BvPKey: Hashable {
        let batterId: Int
        let pitcherId: Int
    }

    // MARK: - Init

    init(gamePk: Int, venueName: String) {
        self.gamePk = gamePk
        self.venueName = venueName
    }

    // MARK: - Lifecycle

    func startPolling() {
        isFirstPoll = true
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.nextInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func handleForeground() {
        pollingTask?.cancel()
        startPolling()
    }

    // MARK: - Poll

    private var pollInFlight = false

    private func poll() async {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        do {
            let feed = try await api.fetchLiveFeed(gamePk: gamePk)
            consecutiveFailures = 0
            connectionStatus = .ok
            requestCount += 1
            lastUpdated = Date()
            debugInfo.lastResponseTime = Date()
            debugInfo.requestCount = requestCount

            await processFeed(feed)
        } catch {
            consecutiveFailures += 1
            switch consecutiveFailures {
            case 1, 2:
                connectionStatus = .retrying(lastUpdated: lastUpdated ?? Date(), failures: consecutiveFailures)
            default:
                connectionStatus = .degraded(since: lastUpdated ?? Date())
            }
        }
    }

    // MARK: - Feed Processing

    private func processFeed(_ feed: LiveFeedResponse) async {
        let status = feed.gameData.status.detailedState

        switch status {
        case "Scheduled", "Pre-Game", "Warmup":
            await handlePreGame(feed)

        case "In Progress":
            await handleInProgress(feed)

        case let s where s.hasPrefix("Delayed"):
            let isPreGame = ["Scheduled", "Pre-Game", "Warmup"].contains(s)
            uiState = .delay(DelayInfo(reason: s, isPreGame: isPreGame))

        case "Suspended":
            uiState = .suspended

        case "Final", "Game Over", "Completed Early":
            handleFinal(feed)
            stopPolling()

        case "Postponed":
            uiState = .postponed(extractPostponedReason(from: status))
            stopPolling()

        default:
            await handleInProgress(feed)
        }
    }

    // MARK: - Pre-Game

    private func handlePreGame(_ feed: LiveFeedResponse) async {
        let home = feed.gameData.teams.home
        let away = feed.gameData.teams.away

        let homeProb = feed.gameData.probablePitchers?.home
        let awayProb = feed.gameData.probablePitchers?.away

        var homePitcherName: String? = homeProb?.fullName
        var awayPitcherName: String? = awayProb?.fullName
        var homeHand: String?
        var awayHand: String?

        // Fetch pitcher handedness if we have IDs
        if let hId = homeProb?.id {
            if let info = await getOrFetchPlayer(id: hId) {
                homePitcherName = info.fullName
                homeHand = info.pitchHand.map { "\($0.displayCode)HP" }
            }
        }
        if let aId = awayProb?.id {
            if let info = await getOrFetchPlayer(id: aId) {
                awayPitcherName = info.fullName
                awayHand = info.pitchHand.map { "\($0.displayCode)HP" }
            }
        }

        let firstPitch: Date? = feed.gameData.datetime?.dateTime.flatMap { parseISO($0) }

        uiState = .preGame(PreGameInfo(
            venueName: venueName,
            homeTeam: home.name,
            awayTeam: away.name,
            firstPitch: firstPitch,
            homePitcher: homePitcherName,
            awayPitcher: awayPitcherName,
            homeHand: homeHand,
            awayHand: awayHand
        ))
    }

    // MARK: - In Progress

    private func handleInProgress(_ feed: LiveFeedResponse) async {
        guard let linescore = feed.liveData?.linescore else { return }

        let inningState = linescore.inningState ?? "Top"

        // Between-innings
        if inningState == "End" || inningState == "Middle" {
            let inning = linescore.currentInning ?? 1
            let nextTeam: String = {
                if inningState == "End" {
                    return feed.gameData.teams.away.abbreviation ?? feed.gameData.teams.away.name
                } else {
                    return feed.gameData.teams.home.abbreviation ?? feed.gameData.teams.home.name
                }
            }()
            uiState = .betweenInnings(BetweenInningsInfo(
                inning: inning,
                inningState: inningState,
                nextTeam: nextTeam,
                venueName: venueName
            ))
            return
        }

        // Build TickState
        guard let currentPlay = feed.liveData?.plays?.currentPlay else { return }
        let matchup = currentPlay.matchup
        guard let batterId = matchup?.batter?.id,
              let pitcherId = matchup?.pitcher?.id else { return }

        let balls = linescore.balls ?? currentPlay.count?.balls ?? 0
        let strikes = linescore.strikes ?? currentPlay.count?.strikes ?? 0
        let outs = linescore.outs ?? currentPlay.count?.outs ?? 0
        let inning = linescore.currentInning ?? 1
        let offense = linescore.offense

        let runnersCode: String = {
            let on1 = offense?.onFirst != nil ? "1" : "_"
            let on2 = offense?.onSecond != nil ? "2" : "_"
            let on3 = offense?.onThird != nil ? "3" : "_"
            return "\(on1)\(on2)\(on3)"
        }()

        let newTick = TickState(
            atBatIndex: currentPlay.atBatIndex,
            batterId: batterId,
            pitcherId: pitcherId,
            balls: balls,
            strikes: strikes,
            outs: outs,
            runnersCode: runnersCode,
            inningState: inningState,
            halfInning: inning
        )

        let refreshKind = diffTickState(old: lastTickState, new: newTick)
        debugInfo.lastRefreshKind = "\(refreshKind)"

        if refreshKind == .none && lastTickState != nil { return }

        // Track reliever first-batter
        if pitcherFirstAtBat[pitcherId] == nil {
            pitcherFirstAtBat[pitcherId] = currentPlay.atBatIndex
        }
        let isFirstBatter = pitcherFirstAtBat[pitcherId] == currentPlay.atBatIndex

        // Fetch data based on refresh kind
        switch refreshKind {
        case .countOnly:
            // Update count + pitcher game stats (pitch count changes every pitch)
            if case .live(let card) = uiState {
                let newSit = SituationStrip(
                    inning: card.situation.inning,
                    inningState: inningState,
                    outs: outs,
                    runners: card.situation.runners,
                    balls: balls,
                    strikes: strikes
                )
                uiState = .live(MatchupCard(
                    batter: card.batter,
                    pitcher: card.pitcher,
                    situation: newSit,
                    bvp: card.bvp,
                    splits: card.splits,
                    batterGame: card.batterGame,
                    pitcherGame: extractPitcherGame(playerId: newTick.pitcherId, feed: feed)
                ))
            }

        case .situational:
            await refreshSituational(tick: newTick, feed: feed, isFirstBatter: isFirstBatter)

        case .full:
            await refreshFull(tick: newTick, feed: feed, isFirstBatter: isFirstBatter)

        case .none:
            break
        }

        lastTickState = newTick
    }

    // MARK: - Situational Refresh

    private func refreshSituational(tick: TickState, feed: LiveFeedResponse, isFirstBatter: Bool) async {
        guard case .live(let existing) = uiState else { return }

        let runners = RunnersState.from(
            onFirst: tick.runnersCode.contains("1"),
            onSecond: tick.runnersCode.contains("2"),
            onThird: tick.runnersCode.contains("3")
        )
        let sit = SituationStrip(
            inning: tick.halfInning,
            inningState: tick.inningState,
            outs: tick.outs,
            runners: runners,
            balls: tick.balls,
            strikes: tick.strikes
        )

        // Fetch fresh season splits; career splits still cached
        let careerBatterSplits = cachedSplits(for: tick.batterId, isCareer: true)
        let seasonBatterSplits = await fetchSplits(
            playerId: tick.batterId,
            codes: SplitPriorityEngine.batterSitCodes,
            season: currentSeason(),
            isCareer: false
        )

        let allBatterSplits = careerBatterSplits + seasonBatterSplits
        let careerOPS = careerBvPCache[BvPKey(batterId: tick.batterId, pitcherId: tick.pitcherId)]??.ops

        let pitchCount = currentPitchCount(in: nil)
        let careerPitcherSplits = cachedSplits(for: tick.pitcherId, isCareer: true)
        let seasonPitcherSplits = await fetchSplits(
            playerId: tick.pitcherId,
            codes: SplitPriorityEngine.pitcherSitCodes,
            season: currentSeason(),
            isCareer: false
        )
        let allPitcherSplits = careerPitcherSplits + seasonPitcherSplits

        let (finalSplits, candidateCount) = buildSplitCards(
            tick: tick,
            batterSplits: allBatterSplits,
            pitcherSplits: allPitcherSplits,
            pitchCount: pitchCount,
            isFirstBatter: isFirstBatter,
            careerOPS: careerOPS
        )
        debugInfo.candidateSplits = candidateCount
        debugInfo.shownSplits = finalSplits.count

        uiState = .live(MatchupCard(
            batter: existing.batter,
            pitcher: existing.pitcher,
            situation: sit,
            bvp: existing.bvp,
            splits: finalSplits,
            batterGame: existing.batterGame,
            pitcherGame: extractPitcherGame(playerId: tick.pitcherId, feed: feed)
        ))
    }

    // MARK: - Full Refresh

    private func refreshFull(tick: TickState, feed: LiveFeedResponse, isFirstBatter: Bool) async {
        // Fetch both players in parallel
        async let batter = getOrFetchPlayer(id: tick.batterId)
        async let pitcher = getOrFetchPlayer(id: tick.pitcherId)

        // BvP
        let bvpKey = BvPKey(batterId: tick.batterId, pitcherId: tick.pitcherId)
        let bvp: BvPLine?
        if let cached = careerBvPCache[bvpKey] {
            bvp = cached
        } else {
            bvp = await fetchBvP(batterId: tick.batterId, pitcherId: tick.pitcherId)
            careerBvPCache[bvpKey] = bvp
        }

        // Career splits (cached per player)
        async let careerBatterSplitsResult = fetchCareerSplitsIfNeeded(
            playerId: tick.batterId,
            codes: SplitPriorityEngine.careerBaselineSitCodes,
            group: "hitting"
        )
        async let careerPitcherSplitsResult = fetchCareerSplitsIfNeeded(
            playerId: tick.pitcherId,
            codes: SplitPriorityEngine.pitcherSitCodes,
            group: "pitching"
        )

        // Season splits
        async let seasonBatterSplitsResult = fetchSplits(
            playerId: tick.batterId,
            codes: SplitPriorityEngine.batterSitCodes,
            season: currentSeason(),
            isCareer: false
        )
        async let seasonPitcherSplitsResult = fetchSplits(
            playerId: tick.pitcherId,
            codes: SplitPriorityEngine.pitcherSitCodes,
            season: currentSeason(),
            isCareer: false
        )

        let (batterInfo, pitcherInfo) = await (batter, pitcher)
        let (careerBatter, careerPitcher, seasonBatter, seasonPitcher) = await (
            careerBatterSplitsResult, careerPitcherSplitsResult,
            seasonBatterSplitsResult, seasonPitcherSplitsResult
        )

        guard let bInfo = batterInfo, let pInfo = pitcherInfo else { return }

        let runners = RunnersState.from(
            onFirst: tick.runnersCode.contains("1"),
            onSecond: tick.runnersCode.contains("2"),
            onThird: tick.runnersCode.contains("3")
        )
        let sit = SituationStrip(
            inning: tick.halfInning,
            inningState: tick.inningState,
            outs: tick.outs,
            runners: runners,
            balls: tick.balls,
            strikes: tick.strikes
        )

        let allBatterSplits = careerBatter + seasonBatter
        let allPitcherSplits = careerPitcher + seasonPitcher
        let pitchCount = currentPitchCount(in: feed)

        let (finalSplits, candidateCount) = buildSplitCards(
            tick: tick,
            batterSplits: allBatterSplits,
            pitcherSplits: allPitcherSplits,
            pitchCount: pitchCount,
            isFirstBatter: isFirstBatter,
            careerOPS: bvp?.ops
        )
        debugInfo.candidateSplits = candidateCount
        debugInfo.shownSplits = finalSplits.count

        let batterGame = extractBatterGame(playerId: tick.batterId, feed: feed)
        let pitcherGame = extractPitcherGame(playerId: tick.pitcherId, feed: feed)

        uiState = .live(MatchupCard(
            batter: bInfo,
            pitcher: pInfo,
            situation: sit,
            bvp: bvp,
            splits: finalSplits,
            batterGame: batterGame,
            pitcherGame: pitcherGame
        ))
    }

    // MARK: - Final

    private func handleFinal(_ feed: LiveFeedResponse) {
        let home = feed.gameData.teams.home
        let away = feed.gameData.teams.away
        let linescore = feed.liveData?.linescore
        let decisions = feed.liveData?.decisions

        uiState = .final_(FinalInfo(
            homeTeam: home.abbreviation ?? home.name,
            awayTeam: away.abbreviation ?? away.name,
            homeScore: linescore?.teams?.home.runs ?? 0,
            awayScore: linescore?.teams?.away.runs ?? 0,
            winnerName: decisions?.winner?.fullName,
            winnerRecord: nil,
            loserName: decisions?.loser?.fullName,
            loserRecord: nil,
            saveName: decisions?.save?.fullName
        ))
    }

    // MARK: - Helpers

    private func getOrFetchPlayer(id: Int) async -> PlayerInfo? {
        if let cached = playerCache[id] { return cached }
        do {
            let resp = try await api.fetchPlayer(id: id)
            if let p = resp.people.first {
                let info = p.toPlayerInfo()
                playerCache[id] = info
                return info
            }
        } catch {}
        return nil
    }

    private func fetchBvP(batterId: Int, pitcherId: Int) async -> BvPLine? {
        do {
            let resp = try await api.fetchBvP(batterId: batterId, pitcherId: pitcherId)
            return resp.toBvPLine()
        } catch { return nil }
    }

    private func fetchCareerSplitsIfNeeded(playerId: Int, codes: [String], group: String) async -> [SplitLine] {
        let existing = codes.compactMap { code -> SplitLine? in
            careerSplitCache[CacheKey(playerId: playerId, sitCode: code, isCareer: true)]?.first
        }
        if !existing.isEmpty { return existing }
        // MLB's statSplits endpoint defaults to current season without a season param;
        // pass the current year explicitly so the label matches the data.
        return await fetchSplits(playerId: playerId, codes: codes, season: currentSeason(), isCareer: true)
    }

    private func fetchSplits(playerId: Int, codes: [String], season: Int?, isCareer: Bool) async -> [SplitLine] {
        do {
            let minPA = isCareer ? 25 : 15
            let group = "hitting"
            let resp = try await api.fetchSplits(playerId: playerId, sitCodes: codes, group: group, season: season)
            let scope = season.map { String($0) } ?? "career"
            let lines = resp.toSplitLines(scope: scope, minPA: minPA)
            if isCareer {
                for line in lines {
                    let key = CacheKey(playerId: playerId, sitCode: line.sitCode, isCareer: true)
                    careerSplitCache[key] = [line]
                }
            }
            return lines
        } catch { return [] }
    }

    private func cachedSplits(for playerId: Int, isCareer: Bool) -> [SplitLine] {
        careerSplitCache.keys
            .filter { $0.playerId == playerId && $0.isCareer == isCareer }
            .compactMap { careerSplitCache[$0]?.first }
    }

    private func buildSplitCards(
        tick: TickState,
        batterSplits: [SplitLine],
        pitcherSplits: [SplitLine],
        pitchCount: Int?,
        isFirstBatter: Bool,
        careerOPS: Double?
    ) -> (splits: [SplitLine], candidateCount: Int) {
        var result: [SplitLine] = []

        let isReliever = (pitcherFirstAtBat[tick.pitcherId].map { $0 > 0 }) ?? false
        let pitcherHand = playerCache[tick.pitcherId]?.pitchHand

        let batter3 = SplitPriorityEngine.selectBatterSplits(
            tickState: tick,
            splits: batterSplits,
            pitcherHand: pitcherHand,
            careerOPS: careerOPS,
            maxCount: 3
        )
        result.append(contentsOf: batter3)

        if let pitcherCard = SplitPriorityEngine.selectPitcherSplit(
            tickState: tick,
            splits: pitcherSplits,
            currentPitchCount: pitchCount,
            isReliever: isReliever,
            isFirstBatter: isFirstBatter,
            careerOPS: nil
        ) {
            // Don't show a pitcher split with the same sitCode as a batter split already shown —
            // it would display as an identical label (e.g. "VS LEFT" twice).
            if !result.contains(where: { $0.sitCode == pitcherCard.sitCode }) {
                result.append(pitcherCard)
            }
        }

        return (result, batterSplits.count + pitcherSplits.count)
    }

    private func extractBatterGame(playerId: Int, feed: LiveFeedResponse) -> BatterGameLine? {
        guard let boxTeams = feed.liveData?.boxscore?.teams else { return nil }
        let key = "ID\(playerId)"
        let player = boxTeams.home?.players?[key] ?? boxTeams.away?.players?[key]
        guard let batting = player?.stats?.batting else { return nil }
        return BatterGameLine(
            atBats: batting.atBats ?? 0,
            hits: batting.hits ?? 0,
            rbi: batting.rbi ?? 0
        )
    }

    private func extractPitcherGame(playerId: Int, feed: LiveFeedResponse) -> PitcherGameLine? {
        guard let boxTeams = feed.liveData?.boxscore?.teams else { return nil }
        let key = "ID\(playerId)"
        let player = boxTeams.home?.players?[key] ?? boxTeams.away?.players?[key]
        guard let pitching = player?.stats?.pitching else { return nil }
        return PitcherGameLine(
            pitches: pitching.numberOfPitches ?? 0,
            strikes: pitching.strikes ?? 0,
            inningsPitched: pitching.inningsPitched ?? "0.0",
            strikeOuts: pitching.strikeOuts ?? 0,
            earnedRuns: pitching.earnedRuns ?? 0
        )
    }

    private func currentPitchCount(in feed: LiveFeedResponse?) -> Int? {
        guard let feed,
              let boxTeams = feed.liveData?.boxscore?.teams,
              let pitcherId = lastTickState?.pitcherId else { return nil }
        let playerKey = "ID\(pitcherId)"
        let homePlayer = boxTeams.home?.players?[playerKey]
        let awayPlayer = boxTeams.away?.players?[playerKey]
        return (homePlayer ?? awayPlayer)?.stats?.pitching?.numberOfPitches
    }

    private func nextInterval() -> TimeInterval {
        switch uiState {
        case .preGame(let info):
            if let fp = info.firstPitch {
                let mins = fp.timeIntervalSinceNow / 60
                return mins < 15 ? 30 : 300
            }
            return 300
        case .live:
            return 12
        case .betweenInnings:
            return 15
        case .delay, .suspended:
            return 60
        case .final_, .postponed:
            return .infinity
        case .loading:
            return 12
        }
    }

    private func extractPostponedReason(from state: String) -> String {
        state.replacingOccurrences(of: "Postponed", with: "").trimmingCharacters(in: .whitespaces)
    }

    private func currentSeason() -> Int {
        Calendar.current.component(.year, from: Date())
    }

    private func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: string) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Player Mapping

extension PlayerResponse.PersonDetail {
    func toPlayerInfo() -> PlayerInfo {
        let (feet, inches) = parseHeight(height)
        let bd = birthDate.flatMap { parseDate($0) }
        return PlayerInfo(
            id: id,
            fullName: fullName,
            primaryPosition: primaryPosition?.abbreviation ?? primaryPosition?.code ?? "?",
            batSide: batSide.flatMap { Handedness(rawValue: $0.code) },
            pitchHand: pitchHand.flatMap { Handedness(rawValue: $0.code) },
            heightFeet: feet,
            heightInches: inches,
            weightLbs: weight,
            birthDate: bd,
            teamAbbreviation: currentTeam?.abbreviation
        )
    }

    private func parseHeight(_ h: String?) -> (Int?, Int?) {
        guard let h else { return (nil, nil) }
        // Format: "6' 2\"" or "6'2\""
        let cleaned = h.replacingOccurrences(of: "\"", with: "")
        let parts = cleaned.components(separatedBy: "'")
        guard parts.count >= 2,
              let ft = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let ins = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return (nil, nil) }
        return (ft, ins)
    }

    private func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

