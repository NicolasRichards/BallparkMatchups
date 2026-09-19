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
    }

    private let gamePk: Int
    private let api: MLBAPIClient
    private var socket: GamedaySocket?
    private var listenTask: Task<Void, Never>?

    /// The live mirror of the server's game object.
    private var tree: JSONValue?

    private(set) var stats = PushFeedStats()

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
            _ = await seedFromFullFeed(yielding: continuation, pushUpdateId: event.updateId)
            return
        }

        if event.isFullRefresh {
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
                stats.patchFailures += 1
                stats.lastError = "decode after patch"
                _ = await seedFromFullFeed(yielding: continuation)
                return
            }
            continuation.yield(.feed(decoded))
        } catch {
            stats.patchFailures += 1
            stats.lastError = error.localizedDescription
            _ = await seedFromFullFeed(yielding: continuation)
        }
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
            // Patch a copy: a throw mid-batch would otherwise leave the live
            // mirror half-updated, and the caller cannot tell how far it got.
            var working = tree ?? .object([:])
            for envelope in envelopes {
                try working.apply(envelope.diff)
            }
            tree = working

        case .object:
            // Gameday answered with the whole game object instead of a diff.
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
