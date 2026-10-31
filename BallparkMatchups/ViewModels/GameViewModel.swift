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
    /// When the feed first read "Game Over" without decisions. Polling goes on
    /// until "Final", but not forever if a game never gets there.
    private var awaitingDecisionsSince: Date?

    // In-memory caches
    private var playerCache: [Int: PlayerInfo] = [:]
    private var careerSplitCache: [CareerSplitKey: [SplitLine]] = [:]
    private var shownSplitData: SplitData?
    private var careerBvPCache: [BvPKey: BvPLine?] = [:]
    /// Batter's overall OPS, the baselines the split filter compares against.
    /// nil means the request worked but he has no such line yet.
    private var baselineOPSCache: [BaselineKey: Double?] = [:]
    private var pitcherFirstAtBat: [Int: Int] = [:]  // pitcherId -> first atBatIndex
    private var observedPitcherEntry: Set<Int> = []  // pitchers we saw enter this session

    private let api = MLBAPIClient.shared

    struct DebugInfo {
        var pollingInterval: TimeInterval = 12
        var lastResponseTime: Date?
        var requestCount: Int = 0
        var candidateSplits: Int = 0
        var shownSplits: Int = 0
        /// The largest split response seen this session, before the PA
        /// threshold is applied, and the largest sample in any of them.
        ///
        /// `Candidates` counts splits that already cleared 15 PA (25 for
        /// career), so a zero there cannot distinguish "MLB served rows and
        /// they were all too small" from "MLB served nothing for this
        /// league". For the Fall League those need completely different
        /// answers, so count the rows before the filter too.
        var rawSplitRows: Int = 0
        var rawSplitMaxPA: Int = 0
        /// Which request produced `rawSplitMaxPA` — league, season or career,
        /// hitting or pitching. Without it the number alone is ambiguous: a
        /// 277 PA sample cannot be a Fall League one, but it could have come
        /// either from a sportId=17 request, meaning the parameter is being
        /// ignored, or from a player who resolved to a real MiLB level
        /// earlier in the same game.
        var rawSplitSource: String = ""
        var lastRefreshKind: String = "-"
        var pushEnabled: Bool = false
        var push: PushFeedStats?
    }

    /// Batting and pitching lines share sitCodes (risp, vl, vr…), so a
    /// two-way player needs one entry per group.
    struct CareerSplitKey: Hashable {
        let playerId: Int
        let group: String
    }

    /// The split lines and baselines behind the card on screen, kept so a
    /// count change can re-rank them without a request.
    struct SplitData {
        let batterId: Int
        let pitcherId: Int
        let batterSplits: [SplitLine]
        let pitcherSplits: [SplitLine]
        let baselines: (season: Double?, career: Double?)
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
        startPushIfEnabled()
        // The socket starts by downloading the full feed; polling at the same
        // moment would download it twice.
        beginPollLoop(firstPoll: pushStream != nil ? .afterPushSeed : .now)
    }

    private enum FirstPoll {
        case now
        /// A feed was just processed, so go straight to the interval.
        case skip
        /// Wait for the socket's seed feed, and poll only if it doesn't come.
        case afterPushSeed
    }

    /// Restarts the poll loop alone, leaving the socket as it is. Used when
    /// something has happened that the loop should react to now rather than
    /// after it finishes the sleep it is already in.
    private func beginPollLoop(firstPoll: FirstPoll = .now) {
        pollingTask?.cancel()
        pollGeneration += 1
        let generation = pollGeneration
        // The cancelled loop's poll may not have unwound yet. Its flag would
        // make the new loop's first poll a no-op and then wait a full interval.
        pollInFlight = false
        pollingTask = Task { [weak self] in
            var skipPoll = firstPoll == .skip
            if firstPoll == .afterPushSeed {
                skipPoll = await self?.waitForPushSeed() ?? false
            }
            while !Task.isCancelled {
                guard let self else { return }
                if skipPoll {
                    skipPoll = false
                } else {
                    await self.poll(generation: generation)
                }
                let interval = self.nextInterval()
                guard interval.isFinite else {
                    // Game over (or stopped waiting for W/L/SV): nothing left to
                    // update, so close the socket too instead of leaving it open.
                    self.stopPush()
                    return
                }
                self.currentPollInterval = interval
                self.debugInfo.pollingInterval = interval
                // Cleared only once the interval is set, so the seed's own
                // processFeed doesn't restart the loop into a duplicate poll.
                self.pushSeedPending = false
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Waits up to 10 seconds for the socket's first feed. True when it came,
    /// so the loop can skip a poll that would fetch the same feed.
    private func waitForPushSeed() async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while pushSeedPending, !pushSeedArrived, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return pushSeedArrived
    }

    /// Records that the game is over and gets the poll loop looking for the
    /// final now, rather than at the end of a sleep sized for a game still in
    /// progress. A one-way latch — nothing clears it.
    private func noteGameOver() {
        guard !gameEndAnnounced else { return }
        gameEndAnnounced = true
        // A poll already running recomputes its own interval as it unwinds.
        // Only a discovery from the socket needs the loop restarted.
        if !pollInFlight { beginPollLoop() }
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
        pushSeedPending = true
        pushSeedArrived = false
        pushTask = Task { [weak self] in
            var lastFeedAt: Date?
            for await update in await stream.start() {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .feed(let feed):
                    await self.processFeed(feed)
                    self.lastUpdated = Date()
                    self.connectionStatus = .ok
                    lastFeedAt = Date()
                    if self.pushStream === stream { self.pushSeedArrived = true }
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
                    // nothing to reason about. The stream fetched a full feed
                    // just before this; when it came, don't fetch it again.
                    let justFed = lastFeedAt.map { Date().timeIntervalSince($0) < 5 } ?? false
                    self.beginPollLoop(firstPoll: justFed ? .skip : .now)
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
            // The stream ended without a feed: its first download failed.
            if let self, self.pushStream === stream { self.pushSeedPending = false }
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
        pushSeedPending = false
        let stream = pushStream
        pushStream = nil
        Task { await stream?.stop() }
    }

    // MARK: - Poll

    private var pollInFlight = false
    /// Bumped by each new poll loop, so a cancelled loop's poll that is still
    /// unwinding can't clear the flag of the poll that replaced it.
    private var pollGeneration = 0
    /// The socket's first full-feed download is under way, and the poll loop
    /// is waiting on it instead of fetching the same feed.
    private var pushSeedPending = false
    private var pushSeedArrived = false
    /// The interval the poll loop is currently sleeping on. Read when a feed
    /// arrives on the socket, to notice that the card now wants checking
    /// sooner than the sleep already under way allows.
    private var currentPollInterval: TimeInterval = 12

    private func poll(generation: Int) async {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { if generation == pollGeneration { pollInFlight = false } }

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

        // The socket can change the card in the middle of the poll loop's
        // sleep, leaving it waiting out an interval sized for the state
        // before. That is most of a minute of a stale card, and it is how a
        // game ending in the 10th kept saying "coming to bat". A poll
        // recomputes on its own as it unwinds, so this is only for push.
        guard !pollInFlight, !pushSeedPending else { return }
        let wanted = nextInterval()
        if wanted.isFinite, wanted < currentPollInterval { beginPollLoop() }
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
        case let s where s.hasPrefix("Game Over"):
            // W/L/SV are published only at "Final", so keep polling for them.
            handleFinal(feed)
            if feed.liveData?.decisions?.winner != nil {
                awaitingDecisionsSince = nil
                stopPolling()
            } else if awaitingDecisionsSince == nil {
                awaitingDecisionsSince = Date()
            }

        case let s where s.hasPrefix("Final")
            || s.hasPrefix("Completed Early") || s.hasPrefix("Forfeit"):
            awaitingDecisionsSince = nil
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
            : feed.gameData.datetime?.dateTime.flatMap(APIDates.parseISO)

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

            if GameCompletion.isOver(inning: inning,
                                     inningState: inningState,
                                     scheduledInnings: scheduledInnings,
                                     homeRuns: homeRuns,
                                     awayRuns: awayRuns) {
                noteGameOver()
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

        let newTick = TickState(
            atBatIndex: currentPlay.atBatIndex,
            batterId: batterId,
            pitcherId: pitcherId,
            balls: balls,
            strikes: strikes,
            outs: outs,
            runners: RunnersState.from(
                onFirst: offense?.onFirst != nil,
                onSecond: offense?.onSecond != nil,
                onThird: offense?.onThird != nil
            ),
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
                // Count splits and pitch-count buckets follow every pitch, so
                // re-rank from the lines already loaded for this matchup.
                var batterSplits = card.batterSplits
                var pitcherSplit = card.pitcherSplit
                if let data = shownSplitData,
                   data.batterId == newTick.batterId, data.pitcherId == newTick.pitcherId {
                    (batterSplits, pitcherSplit) = selectSplits(data, tick: newTick, feed: feed, isFirstBatter: isFirstBatter)
                }
                uiState = .live(MatchupCard(
                    batter: card.batter,
                    pitcher: card.pitcher,
                    situation: newSit,
                    bvp: card.bvp,
                    batterSplits: batterSplits,
                    pitcherSplit: pitcherSplit,
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

        let sit = situation(for: tick)

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

        let data = SplitData(
            batterId: tick.batterId,
            pitcherId: tick.pitcherId,
            batterSplits: cachedCareerSplits(for: tick.batterId, group: "hitting") + seasonBatterSplits,
            pitcherSplits: cachedCareerSplits(for: tick.pitcherId, group: "pitching") + seasonPitcherSplits,
            baselines: baselines
        )
        let (newBatterSplits, newPitcherSplit) = selectSplits(data, tick: tick, feed: feed, isFirstBatter: isFirstBatter)

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
        let bvpLoaded = await bvpResult
        let baselinesLoaded = await baselinesResult
        let (careerBatter, careerPitcher, seasonBatter, seasonPitcher) = await (
            careerBatterSplitsResult, careerPitcherSplitsResult,
            seasonBatterSplitsResult, seasonPitcherSplitsResult
        )

        // Any failed or cancelled request (the phone locked mid-refresh, say)
        // fails the whole card, or a bare one would stick for the at-bat.
        guard !Task.isCancelled,
              let bInfo = batterInfo, let pInfo = pitcherInfo,
              let bvp = bvpLoaded, let baselines = baselinesLoaded,
              let careerBatter, let careerPitcher, let seasonBatter, let seasonPitcher
        else { return false }

        let sit = situation(for: tick)
        let data = SplitData(
            batterId: tick.batterId,
            pitcherId: tick.pitcherId,
            batterSplits: careerBatter + seasonBatter,
            pitcherSplits: careerPitcher + seasonPitcher,
            baselines: baselines
        )
        let (newBatterSplits, newPitcherSplit) = selectSplits(data, tick: tick, feed: feed, isFirstBatter: isFirstBatter)

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
            loserName: decisions?.loser?.fullName,
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
        let resp = career
            ? try await api.fetchCareerHitting(playerId: batterId, sportId: sportId)
            : try await api.fetchSeasonHitting(playerId: batterId, season: currentSeason(), sportId: sportId)
        let ops = resp.lineOPS()
        baselineOPSCache[key] = ops
        return ops
    }

    /// Cache the answer, including "no history", but not a failed request —
    /// that would hide this matchup for the rest of the game. The outer nil
    /// means the request failed; the inner one means no history.
    private func cachedOrFetchBvP(batterId: Int, pitcherId: Int) async -> BvPLine?? {
        let key = BvPKey(batterId: batterId, pitcherId: pitcherId)
        if let cached = careerBvPCache[key] { return cached }
        do {
            // vsPlayer is the batter's own line, so it is scoped to his
            // league. In the Fall League the pitcher may be at another level
            // entirely, in which case there is no head-to-head to find and
            // the card reads "First meeting" — correct, if sparse.
            var line = try await api.fetchBvP(batterId: batterId, pitcherId: pitcherId, sportId: sportId).toBvPLine()
            line?.scope = careerScope(in: sportId)
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
        if let cached = careerSplitCache[CareerSplitKey(playerId: playerId, group: group)] { return cached }
        return await fetchSplits(playerId: playerId, codes: codes, group: group, season: nil, isCareer: true)
    }

    /// nil when the request failed, as opposed to [] for no qualifying splits.
    private func fetchSplits(playerId: Int, codes: [String], group: String, season: Int?, isCareer: Bool) async -> [SplitLine]? {
        do {
            let minPA = SplitThresholds.minPA(isCareer: isCareer, sportId: sportId)
            // Career numbers need their own endpoint: statSplits without a
            // season is only this season, which made the "career" baseline a
            // duplicate of the season request.
            let resp = isCareer
                ? try await api.fetchCareerSplits(playerId: playerId, sitCodes: codes, group: group, sportId: sportId)
                : try await api.fetchSplits(playerId: playerId, sitCodes: codes, group: group, season: season, sportId: sportId)
            let careerLabel = careerScope(in: sportId)
            let scope = isCareer ? careerLabel : season.map { String($0) } ?? careerLabel
            let rawRows = resp.stats.flatMap(\.splits)
            let rawPA = rawRows.compactMap { $0.stat.plateAppearances ?? $0.stat.battersFaced }
            // Running maxima, and for the largest sample, the request that
            // produced it.
            debugInfo.rawSplitRows = max(debugInfo.rawSplitRows, rawRows.count)
            if let best = rawPA.max(), best > debugInfo.rawSplitMaxPA {
                debugInfo.rawSplitMaxPA = best
                debugInfo.rawSplitSource = "@\(sportId) "
                    + (isCareer ? "car " : "ssn ")
                    + (group == "pitching" ? "P" : "H")
            }

            let lines = resp.toSplitLines(scope: scope, isCareer: isCareer, minPA: minPA)
            if isCareer {
                careerSplitCache[CareerSplitKey(playerId: playerId, group: group)] = lines
            }
            return lines
        } catch { return nil }
    }

    private func cachedCareerSplits(for playerId: Int, group: String) -> [SplitLine] {
        careerSplitCache[CareerSplitKey(playerId: playerId, group: group)] ?? []
    }

    private func situation(for tick: TickState) -> SituationStrip {
        SituationStrip(
            inning: tick.halfInning,
            inningState: tick.inningState,
            outs: tick.outs,
            runners: tick.runners,
            balls: tick.balls,
            strikes: tick.strikes
        )
    }

    /// Picks the splits to show and remembers the data they came from.
    private func selectSplits(
        _ data: SplitData,
        tick: TickState,
        feed: LiveFeedResponse,
        isFirstBatter: Bool
    ) -> (batterSplits: [SplitLine], pitcherSplit: SplitLine?) {
        shownSplitData = data
        let pitcherHand = playerCache[tick.pitcherId]?.pitchHand
        let batterHand = playerCache[tick.batterId]?.batSide
        let scoreDiff = scoreDisplay.map { abs($0.homeScore - $0.awayScore) }

        let batter3 = SplitPriorityEngine.selectBatterSplits(
            tickState: tick,
            splits: data.batterSplits,
            pitcherHand: pitcherHand,
            scoreDiff: scoreDiff,
            seasonBaselineOPS: data.baselines.season,
            careerBaselineOPS: data.baselines.career,
            batterHand: batterHand,
            maxCount: 3
        )

        // Handedness sitCodes (vl/vr) mean different things for batters vs pitchers
        // so they are never truly redundant and should not be deduplicated.
        let pitcherSplit = SplitPriorityEngine.selectPitcherSplit(
            tickState: tick,
            splits: data.pitcherSplits,
            currentPitchCount: boxscorePlayer(tick.pitcherId, in: feed)?.stats?.pitching?.numberOfPitches,
            isReliever: pitcherIsReliever(id: tick.pitcherId, in: feed),
            isFirstBatter: isFirstBatter,
            batterHand: batterHand,
            pitcherHand: pitcherHand,
            scoreDiff: scoreDiff,
            excludedCodes: Set(batter3.map(\.sitCode)).subtracting(["vl", "vr"])
        )

        debugInfo.candidateSplits = data.batterSplits.count + data.pitcherSplits.count
        debugInfo.shownSplits = batter3.count + (pitcherSplit != nil ? 1 : 0)
        return (batter3, pitcherSplit)
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
            guard let list = side?.pitchers?.compactMap({ $0 }),
                  let index = list.firstIndex(of: id) else { continue }
            return index > 0
        }
        return false
    }

    private func boxscorePlayer(
        _ id: Int, in feed: LiveFeedResponse
    ) -> LiveFeedResponse.LiveData.Boxscore.BoxscoreTeams.TeamBox.BoxPlayer? {
        guard let teams = feed.liveData?.boxscore?.teams else { return nil }
        let key = "ID\(id)"
        return teams.home?.players?[key] ?? teams.away?.players?[key]
    }

    private func extractBatterGame(playerId: Int, feed: LiveFeedResponse) -> BatterGameLine? {
        guard let batting = boxscorePlayer(playerId, in: feed)?.stats?.batting else { return nil }
        return BatterGameLine(
            atBats: batting.atBats ?? 0,
            hits: batting.hits ?? 0,
            rbi: batting.rbi ?? 0
        )
    }

    private func extractPitcherGame(playerId: Int, feed: LiveFeedResponse) -> PitcherGameLine? {
        guard let pitching = boxscorePlayer(playerId, in: feed)?.stats?.pitching else { return nil }
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
            .compactMap({ $0 })
            .last(where: { $0.about?.isComplete == true })?
            .result?.description
    }

    private func nextInterval() -> TimeInterval {
        PollSchedule.interval(PollSchedule.Inputs(
            state: uiState,
            pushIsHealthy: pushIsHealthy,
            gameEndAnnounced: gameEndAnnounced,
            scheduledInnings: scheduledInnings,
            betweenInningsStart: betweenInningsStart,
            sawBreakStart: sawBreakStart,
            awaitingDecisions: awaitingDecisionsSince.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
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
}

// MARK: - Player Mapping

extension PlayerResponse.PersonDetail {
    func toPlayerInfo() -> PlayerInfo {
        let (feet, inches) = parseHeight(height)
        let bd = birthDate.flatMap(APIDates.parseDay)
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
}

