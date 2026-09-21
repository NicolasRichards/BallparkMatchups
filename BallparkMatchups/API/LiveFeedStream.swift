import Foundation

// MARK: - Stats

/// Counters for the debug overlay, so the push path can be judged on a real game
/// rather than trusted on principle.
struct PushFeedStats: Sendable, Equatable {
    var isConnected = false
    /// Why the socket is down, when it is. A silent drop is undiagnosable.
    var socketNote: String?
    var updatesApplied = 0
    var fullRefreshes = 0
    var patchFailures = 0
    var duplicateOrEmpty = 0
    /// Frames the socket delivered that did not decode as a push event.
    var unrecognisedFrames = 0
    /// A truncated copy of the most recent such frame.
    var lastFrame: String?
    /// Set only when a patch is actually applied — distinct from lastUpdateAt,
    /// which a seed also bumps. Backing the poll loop off must depend on
    /// patches genuinely arriving, not merely on the socket being open.
    var lastPatchAt: Date?

    // Why a full refetch happened. Full refresh climbing at the same rate as
    // Patched wipes out the saving, and these three causes need different
    // fixes, so they are counted apart.
    /// Gameday sent changeEvent.type == "full_refresh".
    var refreshRequestedByServer = 0
    /// We had no metaData.timeStamp to send as startTimecode.
    var refreshForMissingTimecode = 0
    /// diffPatch answered with a whole game object instead of a change set.
    /// Counted as an update, but it costs a full feed.
    var wholeObjectResponses = 0
    /// Total RFC 6902 operations applied, to show how small real diffs are.
    var patchOpsApplied = 0
    /// Reset by any successful patch; the kill switch trips on this.
    var consecutivePatchFailures = 0
    /// Set when the push path has shut itself down for this session.
    var disabledReason: String?
    /// The exact operation that failed, e.g. `remove /liveData/plays/.../0`.
    /// The message alone does not say which path, and the path is the thing
    /// that identifies the bug.
    var lastFailedOperation: String?
    var bytesOverPush = 0
    /// What the same updates would have cost as full-feed polls, using the most
    /// recent full feed as the per-poll size.
    var lastFullFeedBytes = 0
    var lastUpdateAt: Date?
    var lastError: String?

    var estimatedPollingBytes: Int {
        (updatesApplied + fullRefreshes) * lastFullFeedBytes
    }
}

// MARK: - Live Feed Stream

/// Keeps a local copy of GUMBO current by applying `diffPatch` change sets
/// pushed over the Gameday socket, and hands the caller a decoded feed each time
/// it changes.
///
/// The tree is held raw because patch paths reach into fields the typed models
/// never decode. `LiveFeedResponse` is re-derived after each change, so the rest
/// of the app is unaware this is not a poll.
///
/// Every failure path ends in a full refetch. A partially applied patch means the
/// local copy no longer matches the server's, and stale-but-wrong is worse than
/// a wasted request.
actor LiveFeedStream {
    enum Update: Sendable {
        case feed(LiveFeedResponse)
        case gameFinished
        /// The push path gave up. The caller must fall back to polling alone.
        case disabled(reason: String)
    }

    private let gamePk: Int
    private let api: MLBAPIClient
    private var socket: GamedaySocket?
    private var listenTask: Task<Void, Never>?

    /// The live mirror of the server's game object.
    private var tree: JSONValue?

    private(set) var stats = PushFeedStats()

    /// A push path that keeps failing is worse than no push path at all: every
    /// failure costs a full refetch while the backstop poll still runs. Rather
    /// than quietly burning a phone's data on cell service, it stops.
    ///
    /// Scoped to this game session only — the stored flag is left alone, so a
    /// transient problem does not silently cost the feature for good. Worst
    /// case is a handful of wasted refetches per game, which is nothing beside
    /// what polling a whole game costs anyway.
    private static let consecutiveFailureLimit = 3
    private var shouldDisable = false

    init(gamePk: Int, api: MLBAPIClient = .shared) {
        self.gamePk = gamePk
        self.api = api
    }

    func currentStats() -> PushFeedStats { stats }

    // MARK: Lifecycle

    func start() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        listenTask = Task { [weak self] in
            await self?.run(yielding: continuation)
        }
        return stream
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        let socket = self.socket
        self.socket = nil
        Task { await socket?.close() }
        stats.isConnected = false
    }

    // MARK: Main loop

    private func run(yielding continuation: AsyncStream<Update>.Continuation) async {
        let socket = GamedaySocket(gamePk: gamePk)
        self.socket = socket

        // Seed the mirror before the first patch arrives; a patch against an
        // empty tree is meaningless.
        guard await seedFromFullFeed(yielding: continuation) else {
            continuation.finish()
            return
        }

        for await event in await socket.events() {
            if Task.isCancelled { break }
            switch event {
            case .connecting:
                stats.isConnected = false
                stats.socketNote = "handshake…"

            case .opened:
                stats.isConnected = true
                stats.socketNote = nil

            case .disconnected(let reason):
                stats.isConnected = false
                stats.socketNote = reason

            case .unrecognisedFrame(let text):
                stats.unrecognisedFrames += 1
                stats.lastFrame = text

            case .gameFinished:
                // The socket closes on its own here. Take one last full copy so
                // the final line score is the server's, not our patched guess.
                _ = await seedFromFullFeed(yielding: continuation)
                continuation.yield(.gameFinished)
                continuation.finish()
                return

            case .update(let pushEvent):
                await handle(pushEvent, yielding: continuation)
                if shouldDisable {
                    await socket.close()
                    continuation.finish()
                    return
                }
            }
        }
        continuation.finish()
    }

    // MARK: Update handling

    private func handle(
        _ event: GamedayPushEvent,
        yielding continuation: AsyncStream<Update>.Continuation
    ) async {
        guard let timecode = currentTimecode() else {
            stats.refreshForMissingTimecode += 1
            _ = await seedFromFullFeed(yielding: continuation, pushUpdateId: event.updateId)
            return
        }

        if event.isFullRefresh {
            stats.refreshRequestedByServer += 1
            _ = await seedFromFullFeed(yielding: continuation, pushUpdateId: event.updateId)
            return
        }

        do {
            let response = try await api.fetchDiffPatch(
                gamePk: gamePk,
                startTimecode: timecode,
                pushUpdateId: event.updateId
            )
            try applyResponse(response.value)
            stats.updatesApplied += 1
            stats.lastUpdateAt = Date()
            stats.lastPatchAt = Date()
            stats.bytesOverPush += response.byteCount

            guard let decoded = try? tree?.decoded(as: LiveFeedResponse.self) else {
                // The tree no longer decodes — treat that exactly like a failed
                // patch rather than shipping a half-updated card.
                await recordFailure("decode after patch", yielding: continuation)
                return
            }
            stats.consecutivePatchFailures = 0
            continuation.yield(.feed(decoded))
        } catch {
            await recordFailure(error.localizedDescription, yielding: continuation)
        }
    }

    /// Records a failed update and trips the kill switch once they stack up.
    ///
    /// A seed failure is not counted — that is ordinary network trouble, and
    /// polling would be failing too.
    private func recordFailure(
        _ reason: String,
        yielding continuation: AsyncStream<Update>.Continuation
    ) async {
        stats.patchFailures += 1
        stats.consecutivePatchFailures += 1
        stats.lastError = reason

        guard stats.consecutivePatchFailures >= Self.consecutiveFailureLimit else {
            _ = await seedFromFullFeed(yielding: continuation)
            return
        }

        let note = "\(stats.consecutivePatchFailures) failures in a row — \(reason)"
        stats.disabledReason = note
        stats.isConnected = false
        shouldDisable = true
        continuation.yield(.disabled(reason: note))
    }

    /// Applies a `diffPatch` response, which is either a list of change sets or
    /// an entire replacement game object.
    private func applyResponse(_ response: JSONValue) throws {
        switch response {
        case .array(let elements):
            guard !elements.isEmpty else {
                stats.duplicateOrEmpty += 1
                return
            }
            let envelopes = try elements.map { try $0.decoded(as: DiffPatchEnvelope.self) }
            stats.patchOpsApplied += envelopes.reduce(0) { $0 + $1.diff.count }
            // Patch a copy: a throw mid-batch would otherwise leave the live
            // mirror half-updated, and the caller cannot tell how far it got.
            var working = tree ?? .object([:])
            for envelope in envelopes {
                for operation in envelope.diff {
                    do {
                        try working.apply(operation)
                    } catch {
                        // Record which operation failed before rethrowing.
                        // "Index 0 out of bounds" says nothing about where.
                        stats.lastFailedOperation =
                            "\(operation.op.rawValue) \(operation.path)"
                        throw error
                    }
                }
            }
            tree = working

        case .object:
            // Gameday answered with the whole game object instead of a diff.
            // This costs a full feed, so it is worth knowing how often it
            // happens — it is the difference between saving 85% and saving
            // nothing.
            stats.wholeObjectResponses += 1
            tree = response

        default:
            throw JSONPatchError.notTraversable("diffPatch response root")
        }
    }

    // MARK: Full refresh

    @discardableResult
    private func seedFromFullFeed(
        yielding continuation: AsyncStream<Update>.Continuation,
        pushUpdateId: String? = nil
    ) async -> Bool {
        do {
            let raw = try await api.fetchLiveFeedRaw(gamePk: gamePk, pushUpdateId: pushUpdateId)
            tree = raw.value
            stats.lastFullFeedBytes = raw.byteCount
            stats.bytesOverPush += raw.byteCount
            stats.fullRefreshes += 1
            stats.lastUpdateAt = Date()
            let feed = try raw.value.decoded(as: LiveFeedResponse.self)
            continuation.yield(.feed(feed))
            return true
        } catch {
            stats.lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Helpers

    private func currentTimecode() -> String? {
        guard let tree,
              case .string(let value)? = tree.value(
                  at: JSONPointer(tokens: ["metaData", "timeStamp"])
              )
        else { return nil }
        return value
    }
}
