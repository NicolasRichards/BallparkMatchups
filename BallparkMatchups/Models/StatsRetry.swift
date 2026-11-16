import Foundation

/// Tracks an at-bat whose card was built without all of its stats, and says
/// when to try loading them again.
///
/// A stats request that fails must not hold the card back: the previous
/// batter's would stay on screen in its place for as long as the request kept
/// failing. So the card is built with whatever loaded, and this decides when to
/// go back for the rest — a few times, further apart each time. A dropped
/// request is recovered within seconds; one that fails every time is not
/// re-sent on every pitch.
struct StatsRetry: Equatable {
    /// Retries after the first attempt. With the delays below, the last one
    /// comes no sooner than 35 seconds after the card first appeared.
    static let limit = 3
    /// The wait before the first retry. Each later one waits twice as long.
    static let firstDelay: TimeInterval = 5

    let atBatIndex: Int
    let batterId: Int
    let pitcherId: Int
    /// Retries made so far.
    private(set) var attempts = 0
    private(set) var lastAttempt: Date

    init(tick: TickState, now: Date = Date()) {
        atBatIndex = tick.atBatIndex
        batterId = tick.batterId
        pitcherId = tick.pitcherId
        lastAttempt = now
    }

    /// Whether this is the at-bat the record was made for. A later at-bat
    /// between the same two players gets a fresh set of retries.
    func covers(_ tick: TickState) -> Bool {
        atBatIndex == tick.atBatIndex && batterId == tick.batterId && pitcherId == tick.pitcherId
    }

    /// Whether another attempt is due for this at-bat.
    func isDue(for tick: TickState, now: Date = Date()) -> Bool {
        guard covers(tick), attempts < Self.limit else { return false }
        let wait = Self.firstDelay * pow(2, Double(attempts))
        return now.timeIntervalSince(lastAttempt) >= wait
    }

    /// Records a retry that still came back incomplete.
    mutating func noteRetry(now: Date = Date()) {
        attempts += 1
        lastAttempt = now
    }
}
