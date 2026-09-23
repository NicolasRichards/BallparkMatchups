import Foundation

// MARK: - Push Event

/// A message pushed over the Gameday socket.
///
/// The socket itself carries almost no game data — it is a doorbell. The payload
/// that matters is fetched afterwards, keyed by `updateId`.
struct GamedayPushEvent: Decodable, Sendable {
    /// Only `updateId` is required — it is the one field a diffPatch call
    /// cannot be made without. Everything else is optional, because a frame
    /// that merely omits a field should still be actionable rather than
    /// silently discarded as unrecognised.
    let updateId: String
    let timeStamp: String?
    let gamePk: Int?
    let gameEvents: [String]?
    let logicalEvents: [String]?
    let changeEvent: ChangeEvent?

    struct ChangeEvent: Decodable, Sendable {
        let type: String?
    }

    private enum CodingKeys: String, CodingKey {
        case updateId, timeStamp, gamePk, gameEvents, logicalEvents, changeEvent
    }

    /// Decoded field by field rather than synthesised, so one surprising type
    /// cannot sink the whole frame.
    ///
    /// Gameday sends `gamePk` as a quoted string — `"gamePk":"823898"` — even
    /// though MLB's own typings call it a number. Synthesised decoding threw on
    /// that and every event was discarded as unrecognised. Nothing here is
    /// worth failing a frame over except `updateId`, which diffPatch cannot be
    /// called without.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateId = try c.decode(String.self, forKey: .updateId)
        timeStamp = try? c.decodeIfPresent(String.self, forKey: .timeStamp)
        gameEvents = try? c.decodeIfPresent([String].self, forKey: .gameEvents)
        logicalEvents = try? c.decodeIfPresent([String].self, forKey: .logicalEvents)
        changeEvent = try? c.decodeIfPresent(ChangeEvent.self, forKey: .changeEvent)

        if let n = try? c.decodeIfPresent(Int.self, forKey: .gamePk) {
            gamePk = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .gamePk) {
            gamePk = Int(s)
        } else {
            gamePk = nil
        }
    }

    /// Gameday sometimes decides the client should throw its copy away and start
    /// over. It does not explain why, so the only correct response is to comply.
    var isFullRefresh: Bool { changeEvent?.type == "full_refresh" }

    var isGameFinished: Bool { gameEvents?.contains("game_finished") ?? false }
}

// MARK: - Socket

/// A reconnecting client for `wss://ws.statsapi.mlb.com/…/push/subscribe/gameday/{gamePk}`.
///
/// Emits deduplicated push events. Reconnection is automatic and silent; the
/// consumer sees a gap in events, not an error, and the caller's polling backstop
/// covers that gap.
actor GamedaySocket {
    enum Event: Sendable {
        /// A frame arrived that did not decode as a push event. Carries a
        /// truncated copy so it can be read off the debug overlay.
        case unrecognisedFrame(String)
        /// The task has been resumed. The handshake may still fail.
        case connecting
        /// A frame actually arrived, so the connection is genuinely up.
        case opened
        case update(GamedayPushEvent)
        case gameFinished
        /// Carries why, because a silent drop is undiagnosable.
        case disconnected(reason: String)
    }

    private let gamePk: Int
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var pumpTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var closed = false

    /// Duplicate suppression. Gameday occasionally sends the same update twice
    /// with different `updateId`s, microseconds apart. They are identical
    /// otherwise, so timestamp plus payload size separates them reliably.
    private var lastTimeStamp: String?
    private var lastPayloadLength: Int?

    private var reconnectAttempt = 0
    private var hasReceivedFrame = false

    private static let heartbeatMessage = "Gameday5"
    private static let heartbeatInterval: Duration = .seconds(10)
    private static let maxReconnectDelay: Double = 30

    init(gamePk: Int, session: URLSession? = nil) {
        self.gamePk = gamePk
        // URLSession.shared carries a 60s timeoutIntervalForRequest, which also
        // bounds how long a websocket read may wait. Gameday can easily go
        // quiet for longer than that between pitches, so the shared session
        // would drop the connection on its own.
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3600
            config.timeoutIntervalForResource = 86_400
            config.waitsForConnectivity = true
            return URLSession(configuration: config)
        }()
    }

    func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.close() }
        }
        connect()
        return stream
    }

    func close() {
        closed = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: Connection

    private func connect() {
        guard !closed else { return }
        guard let url = URL(
            string: "wss://ws.statsapi.mlb.com/api/v1/game/push/subscribe/gameday/\(gamePk)"
        ) else { return }

        let task = session.webSocketTask(with: url)
        socket = task
        hasReceivedFrame = false
        task.resume()
        continuation?.yield(.connecting)
        startHeartbeat()
        pumpTask = Task { [weak self] in
            await self?.pump()
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self else { return }
                let sent = await self.sendHeartbeat()
                if !sent { return }
            }
        }
    }

    private func sendHeartbeat() async -> Bool {
        guard let socket, !closed else { return false }
        do {
            try await socket.send(.string(Self.heartbeatMessage))
            return true
        } catch {
            return false
        }
    }

    /// Reads messages until the socket errors out, then schedules a reconnect.
    private func pump() async {
        while !closed, let socket {
            do {
                let message = try await socket.receive()
                if !hasReceivedFrame {
                    hasReceivedFrame = true
                    continuation?.yield(.opened)
                }
                reconnectAttempt = 0
                handle(message)
            } catch {
                guard !closed else { return }
                continuation?.yield(.disconnected(reason: Self.describe(error, socket: socket)))
                await scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return
        }

        guard let event = try? JSONDecoder().decode(GamedayPushEvent.self, from: data) else {
            // Heartbeat acks and anything else unexpected. Report it rather
            // than dropping it: a socket that is connected but never produces
            // a recognised event is otherwise indistinguishable from a healthy
            // quiet one.
            let text = String(decoding: data.prefix(160), as: UTF8.self)
            continuation?.yield(.unrecognisedFrame(text))
            return
        }

        // Only dedupe when there is a timestamp to compare; two distinct
        // frames that both omit it would otherwise collide on length alone.
        if let ts = event.timeStamp, lastTimeStamp == ts, lastPayloadLength == data.count {
            return
        }
        lastTimeStamp = event.timeStamp
        lastPayloadLength = data.count

        if event.isGameFinished {
            continuation?.yield(.gameFinished)
            return
        }
        continuation?.yield(.update(event))
    }

    /// Close code plus the underlying error, which is the only thing that
    /// distinguishes "MLB rejected us" from "the network went away".
    private static func describe(_ error: Error, socket: URLSessionWebSocketTask) -> String {
        let ns = error as NSError
        let code = socket.closeCode.rawValue
        var parts: [String] = []
        if code != 0 { parts.append("close \(code)") }
        parts.append("\(ns.domain) \(ns.code)")
        parts.append(ns.localizedDescription)
        return parts.joined(separator: " · ")
    }

    private func scheduleReconnect() async {
        guard !closed else { return }
        heartbeatTask?.cancel()
        socket = nil

        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), Self.maxReconnectDelay)
        try? await Task.sleep(for: .seconds(delay))
        guard !closed else { return }
        connect()
    }
}
