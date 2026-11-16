import Foundation

// Stand-ins for the app's FeatureFlags and GamedaySocket, so the simulator can
// switch the push path on and play the part of MLB's socket.

enum FeatureFlags {
    nonisolated(unsafe) static var pushFeedEnabled = false
}

struct GamedayPushEvent: Sendable {
    let updateId: String
    var isFullRefresh = false
}

actor SocketRegistry {
    private var sockets: [Int: GamedaySocket] = [:]
    func register(_ socket: GamedaySocket, gamePk: Int) { sockets[gamePk] = socket }
    func socket(_ gamePk: Int) -> GamedaySocket? { sockets[gamePk] }
}

actor GamedaySocket {
    enum Event: Sendable {
        case unrecognisedFrame(String)
        case connecting
        case opened
        case update(GamedayPushEvent)
        case gameFinished
        case disconnected(reason: String)
    }

    static let registry = SocketRegistry()

    private let gamePk: Int
    private var continuation: AsyncStream<Event>.Continuation?
    private(set) var closed = false

    init(gamePk: Int) { self.gamePk = gamePk }

    func events() async -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        await Self.registry.register(self, gamePk: gamePk)
        continuation.yield(.connecting)
        return stream
    }

    func close() {
        closed = true
        continuation?.finish()
        continuation = nil
    }

    /// The simulator playing MLB.
    func send(_ event: Event) { continuation?.yield(event) }
}
