import Foundation
import Combine

// MARK: - GameViewModel

@MainActor
final class GameViewModel: ObservableObject {
    let gamePk: Int
    let venueName: String

    @Published var uiState: GameUIState = .loading
    @Published var connectionStatus: ConnectionStatus = .ok
    @Published var lastUpdated: Date?
    @Published var scoreDisplay: ScoreDisplay?

    // Debug overlay data
    @Published var debugInfo: DebugInfo = DebugInfo()

    private var pollingTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var pushStream: LiveFeedStream?
    private var lastTickState: TickState?
    private var lastProcessedTimecode: String?
    private var consecutiveFailures = 0
    private var requestCount = 0
    private var betweenInningsStart: Date?
    /// Whether we watched this break begin. If the app opened mid-break, its
    /// real start is unknown and the 2-minute wait can't be trusted.
    private var sawBreakStart = false
    /// The game's league. Stats requests must name it, or a minor-league
    /// player's splits and head-to-head numbers come back empty.
    private var sportId = SportLevel.mlb.rawValue
    /// MLB announced the end of the game on the socket. `detailedState` often
    /// still reads "In Progress" at that moment, so the card must keep looking
    /// rather than settle onto a between-innings timer for an inning that is
    /// never coming.
    private var gameEndAnnounced = false
    /// How many innings this game is scheduled for: 9 normally, 7 for the
    /// short games of a doubleheader. The end-of-game checks compare against
    /// this rather than assuming nine.
    private var scheduledInnings = 9

    // In-memory caches
    private var playerCache: [Int: PlayerInfo] = [:]
    private var careerSplitCache: [CacheKey: [SplitLine]] = [:]
    private var careerBvPCache: [BvPKey: BvPLine?] = [:]
    /// Batter's overall OPS, the baselines the split filter compares against.
    /// nil means the request worked but he has no such line yet.
    private var baselineOPSCache: [BaselineKey: Double?] = [:]
    /// playerId -> the league their real season numbers live in. Only
    /// consulted for Fall League games; see `league(for:)`.
    private var playerLeagueCache: [Int: Int] = [:]
    /// teamId -> league. A club's level never changes mid-season.
    private var teamLeagueCache: [Int: Int] = [:]
    /// In-flight league lookups, so concurrent callers share one request.
    private var leagueLookups: [Int: Task<Int, Never>] = [:]
    private var pitcherFirstAtBat: [Int: Int] = [:]  // pitcherId -> first atBatIndex
    private var observedPitcherEntry: Set<Int> = []  // pitchers we saw enter this session

    private let api = MLBAPIClient.shared

    struct DebugInfo {
        var pollingInterval: TimeInterval = 12
        var lastResponseTime: Date?
        var requestCount: Int = 0
        var candidateSplits: Int = 0
        var shownSplits: Int = 0
        var lastRefreshKind: String = "-"
        /// Resolved league per player, batter then pitcher. 17 means the
        /// lookup fell back to the game's own league, which yields Fall League
        /// samples too small to clear the thresholds.
        var batterLeague: Int?
        var pitcherLeague: Int?
        var pushEnabled: Bool = false
        var push: PushFeedStats?
    }

    struct CacheKey: Hashable {
        let playerId: Int
        let sitCode: String
        let isCareer: Bool
    }

    struct BaselineKey: Hashable {
        let batterId: Int
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
        beginPollLoop()
        startPushIfEnabled()
    }

    /// Restarts the poll loop alone, leaving the socket as it is. Used when
    /// something has happened that the loop should react to now rather than
    /// after it finishes the sleep it is already in.
    private func beginPollLoop() {
        pollingTask?.cancel()
        // The cancelled loop's poll may not have unwound yet. Its flag would
        // make the new loop's first poll a no-op and then wait a full interval.
        pollInFlight = false
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.nextInterval()
                guard interval.isFinite else { return }  // game over — stop the loop
                self.debugInfo.pollingInterval = interval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        stopPush()
    }

    func handleForeground() {
        pollingTask?.cancel()
        stopPush()
        startPolling()
    }

    // MARK: - Push Feed

    /// Subscribes to the Gameday socket when the flag is on.
    ///
    /// Polling is deliberately left running as a backstop rather than switched
    /// off. A missed socket event is invisible — there is nothing to retry and
    /// no error to surface — so the loop keeps ticking at a slow interval and
    /// `diffTickState` discards the redundant work for free.
    private func startPushIfEnabled() {
        // Tearing down first keeps a second startPolling() from stranding a
        // live socket with nothing left holding its handle.
        stopPush()
        guard FeatureFlags.pushFeedEnabled else {
            debugInfo.pushEnabled = false
            return
        }
        debugInfo.pushEnabled = true

        let stream = LiveFeedStream(gamePk: gamePk)
        pushStream = stream
        pushTask = Task { [weak self] in
            for await update in await stream.start() {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .feed(let feed):
                    await self.processFeed(feed)
                    self.lastUpdated = Date()
                    self.connectionStatus = .ok
                case .gameFinished:
                    // Observed on three games running: the last out lands, the
                    // socket says the game is over, and the card sat on "END OF
                    // THE 9TH" until the two-minute break timer expired. Note
                    // it and poll now, so the final status is picked up as soon
                    // as MLB publishes it.
                    self.gameEndAnnounced = true
                    self.debugInfo.push = await stream.currentStats()
                    // Started before stopPush(), which cancels the very task
                    // this runs in. An unstructured Task is not cancelled with
                    // its creator, so either order works — this one leaves
                    // nothing to reason about.
                    self.beginPollLoop()
                    self.stopPush()
                    return
                case .disabled:
                    // Push gave up. Polling is still running and pushIsHealthy
                    // is already false, so the card simply returns to 5s.
                    self.debugInfo.push = await stream.currentStats()
                    self.stopPush()
                    return
                }
                self.debugInfo.push = await stream.currentStats()
            }
        }
    }

    /// Socket state changes inside the stream actor without yielding a feed
    /// update, so the overlay would otherwise show a snapshot frozen at seed
    /// time — before the socket even exists. The poll loop is already ticking,
    /// so refresh from there too.
    private func refreshPushStats() async {
        guard let pushStream else { return }
        debugInfo.push = await pushStream.currentStats()
    }

    private func stopPush() {
        pushTask?.cancel()
        pushTask = nil
        let stream = pushStream
        pushStream = nil
        Task { await stream?.stop() }
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
            await refreshPushStats()

            await processFeed(feed)
        } catch {
            // A poll cancelled by a restart or backgrounding is not a failure
            if Task.isCancelled { return }
            await refreshPushStats()
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

    /// The most recent feed still being processed.
    private var feedProcessing: Task<Void, Never>?

    /// Processes feeds one at a time, in the order they arrive.
    ///
    /// With the push path on, a poll and a push can land together, and the
    /// handlers await network calls. Run side by side, an older feed could
    /// finish after a newer one and overwrite its card; the timecode check in
    /// processFeedInOrder only holds if each feed finishes before the next
    /// starts. Polling alone never overlaps, so this costs it nothing.
    private func processFeed(_ feed: LiveFeedResponse) async {
        let previous = feedProcessing
        let task = Task { [weak self] in
            await previous?.value
            await self?.processFeedInOrder(feed)
        }
        feedProcessing = task
        // Pass cancellation through, so backgrounding still stops the work.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func processFeedInOrder(_ feed: LiveFeedResponse) async {
        // Two sources can deliver a feed once the push path is on, and a slow
        // response can land after a newer one — which would walk the card
        // backwards. GUMBO timecodes are YYYYMMDD_HHMMSS, so they order
        // lexicographically; anything older than what we've already shown is
        // dropped. An equal timecode is let through and costs nothing, since
        // diffTickState resolves it to .none.
        let timecode = feed.metaData.timeStamp
        if let last = lastProcessedTimecode, timecode < last { return }
        lastProcessedTimecode = timecode

        // Always refresh the score header from the latest linescore
        if let ls = feed.liveData?.linescore?.teams {
            scoreDisplay = ScoreDisplay(
                awayAbbr: feed.gameData.teams.away.abbreviation ?? String(feed.gameData.teams.away.name.prefix(3)).uppercased(),
                awayScore: ls.away.runs ?? 0,
                homeAbbr: feed.gameData.teams.home.abbreviation ?? String(feed.gameData.teams.home.name.prefix(3)).uppercased(),
                homeScore: ls.home.runs ?? 0
            )
        }

        if let id = feed.gameData.teams.home.sport?.id { sportId = id }

        let status = feed.gameData.status.detailedState

        // Match each status family by prefix. MLB appends a reason to most of
        // them ("Completed Early: Rain", "Postponed: Rain", "Final: Tied"), and
        // an exact match sent those to the in-progress path, where a finished
        // game polled forever and a postponed one never left the spinner.
        switch status {
        case let s where s.hasPrefix("Final") || s.hasPrefix("Game Over")
            || s.hasPrefix("Completed Early") || s.hasPrefix("Forfeit"):
            handleFinal(feed)
            stopPolling()

        case let s where s.hasPrefix("Postponed"):
            // The cause lives in status.reason, not in detailedState
            uiState = .postponed(feed.gameData.status.reason ?? "")
            stopPolling()

        case let s where s.hasPrefix("Cancelled"):
            uiState = .cancelled(feed.gameData.status.reason ?? "")
            stopPolling()

        case let s where s.hasPrefix("Scheduled") || s == "Pre-Game" || s == "Warmup":
            await handlePreGame(feed)

        case "In Progress":
            await handleInProgress(feed)

        case let s where s.hasPrefix("Delayed"):
            // "Delayed Start: …" means first pitch hasn't happened; a delay with
            // no current inning in the linescore is also pre-game.
            let isPreGame = s.contains("Start")
                || (feed.liveData?.linescore?.currentInning ?? 0) < 1
            uiState = .delay(DelayInfo(reason: s, isPreGame: isPreGame))

        case let s where s.hasPrefix("Suspended"):
            uiState = .suspended

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
            if let info = await getOrFetchPlayer(id: hId, feed: feed) {
                homePitcherName = info.fullName
                homeHand = info.pitchHand.map { "\($0.displayCode)HP" }
            }
        }
        if let aId = awayProb?.id {
            if let info = await getOrFetchPlayer(id: aId, feed: feed) {
                awayPitcherName = info.fullName
                awayHand = info.pitchHand.map { "\($0.displayCode)HP" }
            }
        }

        // A TBD start (game 2 of a doubleheader) carries game 1's time plus five
        // minutes. Treat it as unknown rather than a first pitch long passed.
        let firstPitch: Date? = feed.gameData.status.startTimeTBD == true
            ? nil
            : feed.gameData.datetime?.dateTime.flatMap { parseISO($0) }

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
        if let scheduled = linescore.scheduledInnings { scheduledInnings = scheduled }

        // Between-innings
        if inningState == "End" || inningState == "Middle" {
            let inning = linescore.currentInning ?? 1
            let homeRuns = linescore.teams?.home.runs ?? 0
            let awayRuns = linescore.teams?.away.runs ?? 0

            // Last scheduled inning or later with home team leading: game is over
            // regardless of whether it's Middle (top half done, home doesn't need
            // to bat) or End (bottom half done, home already won). Don't show
            // between-innings.
            if inning >= scheduledInnings && homeRuns > awayRuns {
                return
            }

            let nextTeam: String = {
                if inningState == "End" {
                    return feed.gameData.teams.away.abbreviation ?? feed.gameData.teams.away.name
                } else {
                    return feed.gameData.teams.home.abbreviation ?? feed.gameData.teams.home.name
                }
            }()
            if betweenInningsStart == nil {
                betweenInningsStart = Date()
                // A live card up means we saw the half-inning end just now
                if case .live = uiState { sawBreakStart = true } else { sawBreakStart = false }
            }
            uiState = .betweenInnings(BetweenInningsInfo(
                inning: inning,
                inningState: inningState,
                nextTeam: nextTeam,
                venueName: venueName
            ))
            return
        }

        betweenInningsStart = nil  // new half-inning is underway

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

        var refreshKind = diffTickState(old: lastTickState, new: newTick)
        // Count and situation updates patch the live card in place. With no
        // live card up — play resuming mid-at-bat after a delay or suspension —
        // there is nothing to patch, and the old card would stay up until the
        // at-bat ended. Rebuild instead.
        if case .live = uiState {} else { refreshKind = .full }
        debugInfo.lastRefreshKind = "\(refreshKind)"

        if refreshKind == .none && lastTickState != nil { return }

        // Track reliever first-batter. A pitcher already on the mound when the app
        // opened has no known entry point, so his first observed at-bat is not his
        // first batter faced — only count entries we actually watched happen.
        if pitcherFirstAtBat[pitcherId] == nil {
            pitcherFirstAtBat[pitcherId] = currentPlay.atBatIndex
            if lastTickState != nil { observedPitcherEntry.insert(pitcherId) }
        }
        let isFirstBatter = observedPitcherEntry.contains(pitcherId)
            && pitcherFirstAtBat[pitcherId] == currentPlay.atBatIndex

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
                    batterSplits: card.batterSplits,
                    pitcherSplit: card.pitcherSplit,
                    batterGame: card.batterGame,
                    pitcherGame: extractPitcherGame(playerId: newTick.pitcherId, feed: feed),
                    lastEvent: card.lastEvent
                ))
            }

        case .situational:
            // Same rule as a full refresh: don't record an update whose data
            // failed to load, so the next poll tries again.
            guard await refreshSituational(tick: newTick, feed: feed, isFirstBatter: isFirstBatter) else { return }

        case .full:
            // If the card couldn't be built (a player lookup failed, or the app
            // was backgrounded mid-refresh), leave lastTickState alone so the
            // next update retries. Recording it would turn the rest of this
            // at-bat into count-only updates of the previous batter's card.
            guard await refreshFull(tick: newTick, feed: feed, isFirstBatter: isFirstBatter) else { return }

        case .none:
            break
        }

        lastTickState = newTick
    }

    // MARK: - Situational Refresh

    /// Returns false when the splits could not be loaded.
    private func refreshSituational(tick: TickState, feed: LiveFeedResponse, isFirstBatter: Bool) async -> Bool {
        guard case .live(let existing) = uiState else { return false }

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
        async let seasonBatterResult = fetchSplits(
            playerId: tick.batterId,
            codes: SplitPriorityEngine.batterSitCodes,
            group: "hitting",
            season: currentSeason(),
            isCareer: false
        )
        async let seasonPitcherResult = fetchSplits(
            playerId: tick.pitcherId,
            codes: SplitPriorityEngine.pitcherSitCodes,
            group: "pitching",
            season: currentSeason(),
            isCareer: false
        )
        async let baselinesResult = batterBaselines(tick.batterId)

        guard let seasonBatterSplits = await seasonBatterResult,
              let seasonPitcherSplits = await seasonPitcherResult,
              let baselines = await baselinesResult
        else { return false }

        let allBatterSplits = cachedSplits(for: tick.batterId, isCareer: true) + seasonBatterSplits
        let pitchCount = currentPitchCount(pitcherId: tick.pitcherId, in: feed)
        let allPitcherSplits = cachedSplits(for: tick.pitcherId, isCareer: true) + seasonPitcherSplits

        let (newBatterSplits, newPitcherSplit, candidateCount) = buildSplitCards(
            tick: tick,
            batterSplits: allBatterSplits,
            pitcherSplits: allPitcherSplits,
            pitchCount: pitchCount,
            isFirstBatter: isFirstBatter,
            isReliever: pitcherIsReliever(id: tick.pitcherId, in: feed),
            baselines: baselines
        )
        debugInfo.candidateSplits = candidateCount
        debugInfo.shownSplits = newBatterSplits.count + (newPitcherSplit != nil ? 1 : 0)

        uiState = .live(MatchupCard(
            batter: existing.batter,
            pitcher: existing.pitcher,
            situation: sit,
            bvp: existing.bvp,
            batterSplits: newBatterSplits,
            pitcherSplit: newPitcherSplit,
            batterGame: existing.batterGame,
            pitcherGame: extractPitcherGame(playerId: tick.pitcherId, feed: feed),
            lastEvent: existing.lastEvent
        ))
        return true
    }

    // MARK: - Full Refresh

    /// Returns false when the card could not be built.
    private func refreshFull(tick: TickState, feed: LiveFeedResponse, isFirstBatter: Bool) async -> Bool {
        // Everything below runs in parallel: roughly eight requests to
        // statsapi per new at-bat, most of them cached after the first.
        async let batter = getOrFetchPlayer(id: tick.batterId, feed: feed)
        async let pitcher = getOrFetchPlayer(id: tick.pitcherId, feed: feed)
        async let bvpResult = cachedOrFetchBvP(batterId: tick.batterId, pitcherId: tick.pitcherId)

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
            group: "hitting",
            season: currentSeason(),
            isCareer: false
        )
        async let seasonPitcherSplitsResult = fetchSplits(
            playerId: tick.pitcherId,
            codes: SplitPriorityEngine.pitcherSitCodes,
            group: "pitching",
            season: currentSeason(),
            isCareer: false
        )

        async let baselinesResult = batterBaselines(tick.batterId)

        let (batterInfo, pitcherInfo) = await (batter, pitcher)
        let bvp = await bvpResult
        let baselines = await baselinesResult
        let (careerBatter, careerPitcher, seasonBatter, seasonPitcher) = await (
            careerBatterSplitsResult ?? [], careerPitcherSplitsResult ?? [],
            seasonBatterSplitsResult ?? [], seasonPitcherSplitsResult ?? []
        )

        guard let bInfo = batterInfo, let pInfo = pitcherInfo else { return false }

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
        let pitchCount = currentPitchCount(pitcherId: tick.pitcherId, in: feed)

        let (newBatterSplits, newPitcherSplit, candidateCount) = buildSplitCards(
            tick: tick,
            batterSplits: allBatterSplits,
            pitcherSplits: allPitcherSplits,
            pitchCount: pitchCount,
            isFirstBatter: isFirstBatter,
            isReliever: pitcherIsReliever(id: tick.pitcherId, in: feed),
            baselines: baselines ?? (season: nil, career: nil)
        )
        debugInfo.candidateSplits = candidateCount
        debugInfo.shownSplits = newBatterSplits.count + (newPitcherSplit != nil ? 1 : 0)

        let batterGame = extractBatterGame(playerId: tick.batterId, feed: feed)
        let pitcherGame = extractPitcherGame(playerId: tick.pitcherId, feed: feed)

        uiState = .live(MatchupCard(
            batter: bInfo,
            pitcher: pInfo,
            situation: sit,
            bvp: bvp,
            batterSplits: newBatterSplits,
            pitcherSplit: newPitcherSplit,
            batterGame: batterGame,
            pitcherGame: pitcherGame,
            lastEvent: extractLastEvent(feed: feed)
        ))
        return true
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

    /// The live feed already lists everyone in the game with name, position
    /// and handedness, so a separate lookup is only a fallback for a player
    /// the feed doesn't carry.
    private func getOrFetchPlayer(id: Int, feed: LiveFeedResponse) async -> PlayerInfo? {
        if let cached = playerCache[id] { return cached }
        if let person = feed.gameData.players?.byKey["ID\(id)"] {
            let info = person.toPlayerInfo()
            playerCache[id] = info
            return info
        }
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

    /// The league whose numbers actually describe this player.
    ///
    /// Everywhere but the Fall League this is the game's own league — a
    /// Double-A game is played by Double-A players. AFL rosters are on loan
    /// from clubs across the system, so a Glendale pitcher's real season may
    /// be High-A. Asking for AFL numbers returns a handful of Fall League
    /// plate appearances, which the split thresholds reject, leaving a card
    /// with a name on it and nothing underneath.
    ///
    /// The feed's player block carries no club, so this needs its own lookup;
    /// both steps are cached, and any failure falls back to the game's league
    /// rather than dropping the stat.
    private func league(for playerId: Int) async -> Int {
        guard sportId == SportLevel.fallLeague.rawValue else { return sportId }
        if let cached = playerLeagueCache[playerId] { return cached }
        // Four call sites ask for the same batter's league at once — two
        // baselines, his splits and the head-to-head. Without this they all
        // miss the cache and each runs the pair of lookups.
        if let inFlight = leagueLookups[playerId] { return await inFlight.value }

        let task = Task { await self.resolveLeague(for: playerId) }
        leagueLookups[playerId] = task
        let level = await task.value
        leagueLookups[playerId] = nil
        playerLeagueCache[playerId] = level
        if playerId == lastTickState?.batterId { debugInfo.batterLeague = level }
        if playerId == lastTickState?.pitcherId { debugInfo.pitcherLeague = level }
        return level
    }

    /// currentTeam -> that club's level. Either step failing falls back to the
    /// game's league rather than dropping the stat entirely.
    private func resolveLeague(for playerId: Int) async -> Int {
        let person = try? await api.fetchPlayer(id: playerId)
        guard let teamId = person?.people.first?.currentTeam?.id else { return sportId }
        if let cached = teamLeagueCache[teamId] { return cached }

        let team = try? await api.fetchTeam(id: teamId)
        guard let level = team?.teams.first?.sport?.id else { return sportId }
        teamLeagueCache[teamId] = level
        return level
    }

    /// The batter's season and career OPS in this league, or nil if either
    /// request failed. Only successful answers are cached, so a failure is
    /// tried again on the next refresh.
    private func batterBaselines(_ batterId: Int) async -> (season: Double?, career: Double?)? {
        async let season = baselineOPS(batterId, career: false)
        async let career = baselineOPS(batterId, career: true)
        do {
            return (try await season, try await career)
        } catch { return nil }
    }

    private func baselineOPS(_ batterId: Int, career: Bool) async throws -> Double? {
        let key = BaselineKey(batterId: batterId, isCareer: career)
        if let cached = baselineOPSCache[key] { return cached }
        let batterLeague = await league(for: batterId)
        let resp = career
            ? try await api.fetchCareerHitting(playerId: batterId, sportId: batterLeague)
            : try await api.fetchSeasonHitting(playerId: batterId, season: currentSeason(), sportId: batterLeague)
        let ops = resp.lineOPS()
        baselineOPSCache[key] = ops
        return ops
    }

    /// Cache the answer, including "no history", but not a failed request —
    /// that would hide this matchup for the rest of the game.
    private func cachedOrFetchBvP(batterId: Int, pitcherId: Int) async -> BvPLine? {
        let key = BvPKey(batterId: batterId, pitcherId: pitcherId)
        if let cached = careerBvPCache[key] { return cached }
        do {
            // vsPlayer is the batter's own line, so it is scoped to his
            // league. In the Fall League the pitcher may be at another level
            // entirely, in which case there is no head-to-head to find and
            // the card reads "First meeting" — correct, if sparse.
            let batterLeague = await league(for: batterId)
            var line = try await api.fetchBvP(batterId: batterId, pitcherId: pitcherId, sportId: batterLeague).toBvPLine()
            line?.scope = careerScope(in: batterLeague)
            careerBvPCache[key] = line
            return line
        } catch { return nil }
    }

    /// What a career line covers. The API counts one level at a time, so in
    /// the minors "career" means career at this level.
    private func careerScope(in league: Int) -> String {
        guard league != SportLevel.mlb.rawValue else { return "career" }
        return "\(SportLevel(rawValue: league)?.displayName ?? "minor league") career"
    }

    private func fetchCareerSplitsIfNeeded(playerId: Int, codes: [String], group: String) async -> [SplitLine]? {
        let existing = codes.compactMap { code -> SplitLine? in
            careerSplitCache[CacheKey(playerId: playerId, sitCode: code, isCareer: true)]?.first
        }
        if !existing.isEmpty { return existing }
        return await fetchSplits(playerId: playerId, codes: codes, group: group, season: nil, isCareer: true)
    }

    /// nil when the request failed, as opposed to [] for no qualifying splits.
    private func fetchSplits(playerId: Int, codes: [String], group: String, season: Int?, isCareer: Bool) async -> [SplitLine]? {
        let playerLeague = await league(for: playerId)
        do {
            let minPA = isCareer ? 25 : 15
            // Career numbers need their own endpoint: statSplits without a
            // season is only this season, which made the "career" baseline a
            // duplicate of the season request.
            let resp = isCareer
                ? try await api.fetchCareerSplits(playerId: playerId, sitCodes: codes, group: group, sportId: playerLeague)
                : try await api.fetchSplits(playerId: playerId, sitCodes: codes, group: group, season: season, sportId: playerLeague)
            let careerLabel = careerScope(in: playerLeague)
            let scope = isCareer ? careerLabel : season.map { String($0) } ?? careerLabel
            let lines = resp.toSplitLines(scope: scope, isCareer: isCareer, minPA: minPA)
            if isCareer {
                for line in lines {
                    let key = CacheKey(playerId: playerId, sitCode: line.sitCode, isCareer: true)
                    careerSplitCache[key] = [line]
                }
            }
            return lines
        } catch { return nil }
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
        isReliever: Bool,
        baselines: (season: Double?, career: Double?)
    ) -> (batterSplits: [SplitLine], pitcherSplit: SplitLine?, candidateCount: Int) {
        let pitcherHand = playerCache[tick.pitcherId]?.pitchHand
        let batterHand = playerCache[tick.batterId]?.batSide

        let batter3 = SplitPriorityEngine.selectBatterSplits(
            tickState: tick,
            splits: batterSplits,
            pitcherHand: pitcherHand,
            seasonBaselineOPS: baselines.season,
            careerBaselineOPS: baselines.career,
            maxCount: 3
        )

        // Handedness sitCodes (vl/vr) mean different things for batters vs pitchers
        // so they are never truly redundant and should not be deduplicated.
        let handednessCodes: Set<String> = ["vl", "vr"]
        let pitcherSplit: SplitLine? = SplitPriorityEngine.selectPitcherSplit(
            tickState: tick,
            splits: pitcherSplits,
            currentPitchCount: pitchCount,
            isReliever: isReliever,
            isFirstBatter: isFirstBatter,
            careerOPS: nil,
            batterHand: batterHand
        ).flatMap { card in
            if handednessCodes.contains(card.sitCode) { return card }
            return batter3.contains(where: { $0.sitCode == card.sitCode }) ? nil : card
        }

        return (batter3, pitcherSplit, batterSplits.count + pitcherSplits.count)
    }

    /// True when this pitcher is not his team's starter.
    ///
    /// The boxscore lists each team's pitchers in the order they appeared, so the
    /// first entry is the starter. The previous rule asked whether the pitcher's
    /// first observed at-bat index was above zero, which marked the home starter a
    /// reliever every game (his first at-bat is never index 0) and marked any
    /// starter a reliever when the app opened mid-game.
    private func pitcherIsReliever(id: Int, in feed: LiveFeedResponse) -> Bool {
        guard let teams = feed.liveData?.boxscore?.teams else { return false }
        for side in [teams.home, teams.away] {
            guard let list = side?.pitchers, let index = list.firstIndex(of: id) else { continue }
            return index > 0
        }
        return false
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

    private func extractLastEvent(feed: LiveFeedResponse) -> String? {
        feed.liveData?.plays?.allPlays?
            .last(where: { $0.about?.isComplete == true })?
            .result?.description
    }

    private func currentPitchCount(pitcherId: Int, in feed: LiveFeedResponse) -> Int? {
        guard let boxTeams = feed.liveData?.boxscore?.teams else { return nil }
        let playerKey = "ID\(pitcherId)"
        let homePlayer = boxTeams.home?.players?[playerKey]
        let awayPlayer = boxTeams.away?.players?[playerKey]
        return (homePlayer ?? awayPlayer)?.stats?.pitching?.numberOfPitches
    }

    private func nextInterval() -> TimeInterval {
        PollSchedule.interval(PollSchedule.Inputs(
            state: uiState,
            pushIsHealthy: pushIsHealthy,
            gameEndAnnounced: gameEndAnnounced,
            scheduledInnings: scheduledInnings,
            betweenInningsStart: betweenInningsStart,
            sawBreakStart: sawBreakStart
        ))
    }

    /// Whether the push path has produced an update recently enough to lean on.
    private var pushIsHealthy: Bool {
        // An open socket is not evidence the push path is working. A live run
        // showed it connected, delivering nothing, and the poll loop backing
        // off to 60s anyway — which degrades the card for a real user. Back
        // off only while patches are genuinely arriving.
        guard FeatureFlags.pushFeedEnabled, let push = debugInfo.push,
              push.isConnected, push.updatesApplied > 0,
              let lastPatch = push.lastPatchAt else { return false }
        return Date().timeIntervalSince(lastPatch) < 120
    }

    /// Gregorian explicitly: Calendar.current follows the user's calendar
    /// setting, and the Japanese or Buddhist calendar would give 8 or 2569.
    private func currentSeason() -> Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
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
        // POSIX locale: API dates must not depend on the device's calendar setting
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}

