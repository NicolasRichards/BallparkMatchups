import Foundation

// MARK: - Push Event

/// A message pushed over the Gameday socket.
///
/// The socket itself carries almost no game data — it is a doorbell. The payload
/// that matters is fetched afterwards, keyed by `updateId`.
struct GamedayPushEvent: Decodable, Sendable {
    let timeStamp: String
    let updateId: String
    let gamePk: Int
    let gameEvents: [String]
    let logicalEvents: [String]?
    let changeEvent: ChangeEvent?

    struct ChangeEvent: Decodable, Sendable {
        let type: String
    }

    /// Gameday sometimes decides the client should throw its copy away and start
    /// over. It does not explain why, so the only correct response is to comply.
    var isFullRefresh: Bool { changeEvent?.type == "full_refresh" }

    var isGameFinished: Bool { gameEvents.contains("game_finished") }
}

// MARK: - Socket

/// A reconnecting client for `wss://ws.statsapi.mlb.com/…/push/subscribe/gameday/{gamePk}`.
///
/// Emits deduplicated push events. Reconnection is automatic and silent; the
/// consumer sees a gap in events, not an error, and the caller's polling backstop
/// covers that gap.
actor GamedaySocket {
    enum Event: Sendable {
        case connected
        case update(GamedayPushEvent)
        case gameFinished
        case disconnected
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

    private static let heartbeatMessage = "Gameday5"
    private static let heartbeatInterval: Duration = .seconds(10)
    private static let maxReconnectDelay: Double = 30

    init(gamePk: Int, session: URLSession = .shared) {
        self.gamePk = gamePk
        self.session = session
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
        task.resume()
        continuation?.yield(.connected)
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
                reconnectAttempt = 0
                handle(message)
            } catch {
                guard !closed else { return }
                continuation?.yield(.disconnected)
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
            // Heartbeat acks and other non-event frames land here.
            return
        }

        if lastTimeStamp == event.timeStamp, lastPayloadLength == data.count {
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
