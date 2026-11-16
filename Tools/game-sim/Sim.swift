import Foundation

// Drives the app's real GameViewModel and LiveFeedStream through scripted
// games. Only the network client, the socket and the feature flag are fakes.
// See README.md in this folder; run with ./run.sh.

// MARK: - Feed builder

struct Spec {
    var seq: Int
    var status = "In Progress"
    var inning = 5
    var half = "Top"
    var outs = 1
    var balls = 0
    var strikes = 0
    var atBat = 10
    var batter = 100
    var pitcher = 200
    var on: [String] = []
    var home = 0
    var away = 0
    var people: [Int] = []
}

func timecode(_ seq: Int) -> String {
    String(format: "20260401_19%02d%02d", seq / 60, seq % 60)
}

func feed(_ s: Spec) -> Data {
    func person(_ id: Int) -> String {
        let pitcher = id % 1000 >= 200
        return #""ID\#(id)":{"id":\#(id),"fullName":"Player \#(id)","primaryPosition":{"code":"\#(pitcher ? "1" : "6")","abbreviation":"\#(pitcher ? "P" : "SS")"},"batSide":{"code":"R"},"pitchHand":{"code":"R"}}"#
    }
    let people = Set(s.people + [s.batter, s.pitcher]).sorted().map(person).joined(separator: ",")
    let offense = s.on.map { #""\#($0)":{"id":999}"# }.joined(separator: ",")
    let json = """
    {"metaData":{"timeStamp":"\(timecode(s.seq))"},
     "gameData":{"status":{"detailedState":"\(s.status)"},
       "datetime":{"dateTime":"2026-04-01T23:05:00Z"},
       "teams":{"home":{"id":1,"name":"Home Team","abbreviation":"HOM","sport":{"id":1}},
                "away":{"id":2,"name":"Away Team","abbreviation":"AWY","sport":{"id":1}}},
       "players":{\(people)}},
     "liveData":{
       "plays":{"currentPlay":{"atBatIndex":\(s.atBat),
                  "matchup":{"batter":{"id":\(s.batter)},"pitcher":{"id":\(s.pitcher)}},
                  "count":{"balls":\(s.balls),"strikes":\(s.strikes),"outs":\(s.outs)}},
                "allPlays":[]},
       "linescore":{"currentInning":\(s.inning),"inningState":"\(s.half)","scheduledInnings":9,
                    "balls":\(s.balls),"strikes":\(s.strikes),"outs":\(s.outs),
                    "offense":{\(offense)},
                    "teams":{"home":{"runs":\(s.home)},"away":{"runs":\(s.away)}}},
       "boxscore":{"teams":{"home":{"pitchers":[\(s.pitcher)],"players":{}},
                            "away":{"pitchers":[],"players":{}}}}}}
    """
    return Data(json.utf8)
}

/// A diffPatch answer: the given operations plus the new timestamp.
func patch(_ ops: [String], seq: Int) -> Data {
    let all = ops + [#"{"op":"replace","path":"/metaData/timeStamp","value":"\#(timecode(seq))"}"#]
    return Data(#"[{"diff":[\#(all.joined(separator: ","))]}]"#.utf8)
}

func replace(_ path: String, _ value: String) -> String {
    #"{"op":"replace","path":"\#(path)","value":\#(value)}"#
}

// MARK: - Checks

struct Check: Sendable {
    let scenario: String
    let name: String
    let ok: Bool
    let detail: String
}

func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor func card(_ vm: GameViewModel) -> MatchupCard? {
    if case .live(let c) = vm.uiState { return c }
    return nil
}

@MainActor func stateName(_ vm: GameViewModel) -> String {
    switch vm.uiState {
    case .loading: return "loading"
    case .preGame: return "preGame"
    case .live(let c): return "live(batter \(c.batter.id), \(c.situation.balls)-\(c.situation.strikes), \(c.situation.outs) out, bvp \(c.bvp == nil ? "none" : "yes"), \(c.batterSplits.count) splits)"
    case .betweenInnings(let i): return "break(\(i.inningState) \(i.inning))"
    case .delay: return "delay"
    case .suspended: return "suspended"
    case .final_: return "final"
    case .postponed: return "postponed"
    case .cancelled: return "cancelled"
    }
}

func waitForSocket(_ gamePk: Int) async -> GamedaySocket? {
    for _ in 0..<60 {
        if let s = await GamedaySocket.registry.socket(gamePk) { return s }
        await pause(0.05)
    }
    return nil
}

let api = MLBAPIClient.shared

// MARK: - Poll-path scenarios (push off)

/// The review's case: a stats request that fails every time.
@MainActor func alwaysFailingRequest() async -> [Check] {
    let s = "always-failing request"
    var out: [Check] = []
    let pk = 9001, people = [1100, 1101, 1200]
    await api.script(gamePk: pk, feeds: [
        feed(Spec(seq: 0, atBat: 10, batter: 1100, pitcher: 1200, people: people)),
        feed(Spec(seq: 5, outs: 2, atBat: 11, batter: 1101, pitcher: 1200, people: people)),
        feed(Spec(seq: 10, outs: 2, strikes: 1, atBat: 11, batter: 1101, pitcher: 1200, people: people)),
        feed(Spec(seq: 15, outs: 2, balls: 1, strikes: 1, atBat: 11, batter: 1101, pitcher: 1200, people: people)),
        feed(Spec(seq: 20, outs: 2, balls: 1, strikes: 2, atBat: 11, batter: 1101, pitcher: 1200, people: people)),
        feed(Spec(seq: 25, outs: 2, balls: 2, strikes: 2, atBat: 11, batter: 1101, pitcher: 1200, people: people)),
    ])
    await api.setFailure("bvp:1101", .always)

    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    let t0 = Date()
    vm.startPolling()

    await pause(1.5)
    let first = card(vm)
    out.append(Check(scenario: s, name: "first batter's card is complete",
                     ok: first?.batter.id == 1100 && first?.bvp != nil && !(first?.batterSplits.isEmpty ?? true),
                     detail: stateName(vm)))

    await pause(5.5)   // the poll at ~5s brings the new at-bat
    let second = card(vm)
    out.append(Check(scenario: s, name: "new batter's card appears although his head-to-head request fails",
                     ok: second?.batter.id == 1101, detail: stateName(vm)))
    out.append(Check(scenario: s, name: "…with the stats that did load, and no head-to-head line",
                     ok: second?.bvp == nil && !(second?.batterSplits.isEmpty ?? true), detail: stateName(vm)))

    await pause(5)     // the poll at ~10s is a count change
    let third = card(vm)
    out.append(Check(scenario: s, name: "the count keeps updating on that card",
                     ok: third?.batter.id == 1101 && third?.situation.strikes == 1, detail: stateName(vm)))

    await pause(50)    // to ~62s: all three retries have had their turn
    let hits = await api.hits("bvp:1101").map { $0.at.timeIntervalSince(t0) }
    let gaps = zip(hits.dropFirst(), hits).map { $0 - $1 }
    let times = hits.map { String(format: "%.1fs", $0) }.joined(separator: ", ")
    out.append(Check(scenario: s, name: "the failing request is tried 4 times in all, not on every update",
                     ok: hits.count == 4, detail: "\(hits.count) requests at \(times)"))
    out.append(Check(scenario: s, name: "…waiting about 5s, 10s and 20s between tries",
                     ok: gaps.count == 3 && gaps[0] >= 4.9 && gaps[1] >= 9.9 && gaps[2] >= 19.9,
                     detail: gaps.map { String(format: "%.1fs", $0) }.joined(separator: ", ")))
    let cached = [("careerSplits:hitting:1101", 1), ("seasonLine:1101", 1), ("careerLine:1101", 1)]
    for (key, want) in cached {
        let n = await api.hits(key).count
        out.append(Check(scenario: s, name: "\(key) is not re-requested once it succeeded",
                         ok: n == want, detail: "\(n) requests"))
    }
    let final = card(vm)
    out.append(Check(scenario: s, name: "card still on the new batter with the latest count",
                     ok: final?.batter.id == 1101 && final?.situation.balls == 2 && final?.situation.strikes == 2,
                     detail: stateName(vm)))
    vm.stopPolling()
    return out
}

/// One dropped request, which then works.
@MainActor func droppedRequestRecovers() async -> [Check] {
    let s = "dropped request"
    var out: [Check] = []
    let pk = 9002
    await api.script(gamePk: pk, feeds: [
        feed(Spec(seq: 0, atBat: 20, batter: 2101, pitcher: 2200)),
        feed(Spec(seq: 5, strikes: 1, atBat: 20, batter: 2101, pitcher: 2200)),
        feed(Spec(seq: 10, balls: 1, strikes: 1, atBat: 20, batter: 2101, pitcher: 2200)),
    ])
    await api.setEmpty("careerSplits:hitting:2101")
    await api.setFailure("splits:hitting:2101", .times(1))

    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    await pause(1.5)
    let bare = card(vm)
    out.append(Check(scenario: s, name: "card appears at once without the splits that failed to load",
                     ok: bare?.batter.id == 2101 && bare?.bvp != nil && (bare?.batterSplits.isEmpty ?? false),
                     detail: stateName(vm)))
    await pause(5.5)
    let filled = card(vm)
    out.append(Check(scenario: s, name: "the splits arrive on the retry about 5s later",
                     ok: filled?.batter.id == 2101 && !(filled?.batterSplits.isEmpty ?? true), detail: stateName(vm)))
    await pause(15)
    let n = await api.hits("splits:hitting:2101").count
    out.append(Check(scenario: s, name: "no further retries once the card is complete",
                     ok: n == 2, detail: "\(n) season-split requests"))
    vm.stopPolling()
    return out
}

/// Outs and runners change while the mid-at-bat splits refetch is failing.
@MainActor func situationUpdatesDespiteFailure() async -> [Check] {
    let s = "situation change"
    var out: [Check] = []
    let pk = 9003
    await api.script(gamePk: pk, feeds: [
        feed(Spec(seq: 0, outs: 1, atBat: 30, batter: 3101, pitcher: 3200)),
        feed(Spec(seq: 5, outs: 2, atBat: 30, batter: 3101, pitcher: 3200, on: ["second"])),
    ])
    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    await pause(2)
    let before = card(vm)
    out.append(Check(scenario: s, name: "card complete before the failure starts",
                     ok: before?.situation.outs == 1 && !(before?.batterSplits.isEmpty ?? true), detail: stateName(vm)))
    await api.setFailure("splits:hitting:3101", .always)
    await api.setFailure("splits:pitching:3200", .always)
    await pause(5)
    let after = card(vm)
    out.append(Check(scenario: s, name: "outs and runners update although the splits refetch fails",
                     ok: after?.situation.outs == 2 && (after?.situation.runnersDisplay.contains("2nd") ?? false),
                     detail: stateName(vm) + " · " + (after?.situation.runnersDisplay ?? "-")))
    out.append(Check(scenario: s, name: "…and the splits already loaded are still shown",
                     ok: !(after?.batterSplits.isEmpty ?? true),
                     detail: (after?.batterSplits.map(\.sitCode).joined(separator: ",") ?? "-")))
    vm.stopPolling()
    return out
}

/// Nothing failing: behaviour must be what it was.
@MainActor func normalAtBats() async -> [Check] {
    let s = "normal at-bats"
    var out: [Check] = []
    let pk = 9004, people = [4101, 4102, 4200]
    await api.script(gamePk: pk, feeds: [
        feed(Spec(seq: 0, atBat: 40, batter: 4101, pitcher: 4200, people: people)),
        feed(Spec(seq: 5, strikes: 1, atBat: 40, batter: 4101, pitcher: 4200, people: people)),
        feed(Spec(seq: 10, outs: 2, atBat: 41, batter: 4102, pitcher: 4200, people: people)),
        feed(Spec(seq: 15, outs: 2, balls: 1, atBat: 41, batter: 4102, pitcher: 4200, people: people)),
    ])
    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    var sawRetry = false
    await pause(1.5)
    let a = card(vm)
    out.append(Check(scenario: s, name: "first card complete at once",
                     ok: a?.batter.id == 4101 && a?.bvp != nil && !(a?.batterSplits.isEmpty ?? true) && a?.pitcherSplit != nil,
                     detail: stateName(vm)))
    for _ in 0..<20 {
        await pause(1)
        if vm.debugInfo.lastRefreshKind.contains("retry") { sawRetry = true }
    }
    let b = card(vm)
    out.append(Check(scenario: s, name: "second batter's card complete",
                     ok: b?.batter.id == 4102 && b?.bvp != nil && !(b?.batterSplits.isEmpty ?? true) && b?.situation.balls == 1,
                     detail: stateName(vm)))
    out.append(Check(scenario: s, name: "no retries when nothing failed", ok: !sawRetry, detail: vm.debugInfo.lastRefreshKind))
    let want = [("bvp:4101", 1), ("bvp:4102", 1), ("careerSplits:pitching:4200", 1),
                ("seasonLine:4101", 1), ("careerLine:4101", 1), ("splits:hitting:4101", 1),
                ("splits:hitting:4102", 1), ("splits:pitching:4200", 2)]
    for (key, n) in want {
        let got = await api.hits(key).count
        out.append(Check(scenario: s, name: "\(key): \(n) request\(n == 1 ? "" : "s")", ok: got == n, detail: "\(got)"))
    }
    vm.stopPolling()
    return out
}

/// The phone locks while a card is loading, then unlocks.
@MainActor func cancelledRefreshIsRedone() async -> [Check] {
    let s = "locked mid-refresh"
    var out: [Check] = []
    let pk = 9005
    await api.script(gamePk: pk, feeds: [feed(Spec(seq: 0, atBat: 50, batter: 5101, pitcher: 5200))])
    await api.setLatency("bvp:5101", seconds: 1.5)
    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    await pause(0.6)
    vm.stopPolling()          // what backgrounding does
    await pause(0.6)
    out.append(Check(scenario: s, name: "a half-loaded card is not put up",
                     ok: card(vm) == nil, detail: stateName(vm)))
    await api.setLatency("bvp:5101", seconds: 0.04)
    vm.handleForeground()
    await pause(2)
    let c = card(vm)
    out.append(Check(scenario: s, name: "the at-bat is loaded in full on return",
                     ok: c?.batter.id == 5101 && c?.bvp != nil && !(c?.batterSplits.isEmpty ?? true), detail: stateName(vm)))
    vm.stopPolling()
    return out
}

// MARK: - Push-path scenarios (push on)

/// Brings a game up with the socket open and one patch applied, and waits for
/// the poll loop to settle onto the 60s interval it uses while push is healthy.
@MainActor func healthyPushGame(_ pk: Int, batter: Int, pitcher: Int, inning: Int = 5,
                                home: Int = 0, away: Int = 0) async -> (GameViewModel, GamedaySocket?) {
    await api.pin(gamePk: pk, feed: feed(Spec(seq: 0, inning: inning, outs: 2, atBat: 60, batter: batter, pitcher: pitcher, home: home, away: away)))
    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    let socket = await waitForSocket(pk)
    await pause(1)
    await socket?.send(.opened)
    await api.queueDiffs(gamePk: pk, [.success(patch([replace("/liveData/linescore/strikes", "1")], seq: 10))])
    await socket?.send(.update(GamedayPushEvent(updateId: "healthy")))
    await pause(6.5)   // the loop wakes at ~5s, sees patches arriving, and sleeps 60s
    return (vm, socket)
}

/// Finding: an empty answer reset the three-strike count.
@MainActor func killSwitchTripsDespiteEmptyAnswers() async -> [Check] {
    let s = "kill switch"
    var out: [Check] = []
    let pk = 9101
    await api.pin(gamePk: pk, feed: feed(Spec(seq: 0, atBat: 60, batter: 6101, pitcher: 6200)))
    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    let socket = await waitForSocket(pk)
    await pause(0.5)
    await socket?.send(.opened)
    let empty = Data("[]".utf8)
    await api.queueDiffs(gamePk: pk, [.failure(.always), .success(empty), .failure(.always), .success(empty), .failure(.always)])
    for i in 1...5 {
        await socket?.send(.update(GamedayPushEvent(updateId: "u\(i)")))
        await pause(0.4)
    }
    await pause(1.5)
    let push = vm.debugInfo.push
    out.append(Check(scenario: s, name: "three failed patches with empty answers between them shut push off",
                     ok: push?.disabledReason != nil && push?.patchFailures == 3,
                     detail: "disabled: \(push?.disabledReason ?? "no") · patch fails \(push?.patchFailures ?? -1)"))
    vm.stopPolling()
    return out
}

/// Finding: requests the network never answered counted as failed patches.
@MainActor func unansweredRequestsDoNotCount() async -> [Check] {
    let s = "no answer"
    var out: [Check] = []
    let pk = 9102
    await api.pin(gamePk: pk, feed: feed(Spec(seq: 0, atBat: 60, batter: 6111, pitcher: 6210)))
    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    let socket = await waitForSocket(pk)
    await pause(0.5)
    await socket?.send(.opened)
    await api.queueDiffs(gamePk: pk, [.failure(.offline), .failure(.offline), .failure(.offline), .failure(.offline),
                                      .success(patch([replace("/liveData/linescore/strikes", "1")], seq: 30))])
    for i in 1...4 {
        await socket?.send(.update(GamedayPushEvent(updateId: "u\(i)")))
        await pause(0.3)
    }
    await pause(0.5)
    let rawFetchesAfterOutage = await api.hits("feedRaw:\(pk)").count
    await socket?.send(.update(GamedayPushEvent(updateId: "u5")))
    await pause(1.5)
    let push = vm.debugInfo.push
    out.append(Check(scenario: s, name: "four unanswered requests do not shut push off",
                     ok: push != nil && push?.disabledReason == nil && push?.patchFailures == 0,
                     detail: "disabled: \(push?.disabledReason ?? "no") · patch fails \(push?.patchFailures ?? -1)"))
    out.append(Check(scenario: s, name: "…and cost no re-download of the game",
                     ok: rawFetchesAfterOutage == 1 && push?.fullRefreshes == 1,
                     detail: "\(rawFetchesAfterOutage) full download(s), the first being the one at start-up"))
    out.append(Check(scenario: s, name: "…and are counted for the debug panel",
                     ok: push?.unansweredRequests == 4, detail: "\(push?.unansweredRequests ?? -1)"))
    let c = card(vm)
    out.append(Check(scenario: s, name: "the next update that gets through brings the card up to date",
                     ok: push?.updatesApplied == 1 && c?.situation.strikes == 1, detail: stateName(vm)))
    vm.stopPolling()
    return out
}

/// Finding: when push shut itself off, polling stayed asleep for up to a minute.
@MainActor func pollingRestartsWhenPushShutsOff() async -> [Check] {
    let s = "push shuts off"
    var out: [Check] = []
    let pk = 9103
    let (vm, socket) = await healthyPushGame(pk, batter: 6121, pitcher: 6220)
    out.append(Check(scenario: s, name: "(setup) polling had backed off to 60s behind a healthy socket",
                     ok: vm.debugInfo.pollingInterval == 60, detail: "\(Int(vm.debugInfo.pollingInterval))s"))
    await api.queueDiffs(gamePk: pk, [.failure(.always), .failure(.always), .failure(.always)])
    for i in 1...3 {
        await socket?.send(.update(GamedayPushEvent(updateId: "bad\(i)")))
        await pause(0.2)
    }
    await pause(0.5)
    let mark = Date()
    await pause(13)
    let polls = await api.hits("feed:\(pk)").filter { $0.at > mark }.count
    out.append(Check(scenario: s, name: "polling resumes within seconds of push shutting off",
                     ok: polls >= 2 && vm.debugInfo.push?.disabledReason != nil,
                     detail: "\(polls) polls in the next 13s · interval now \(Int(vm.debugInfo.pollingInterval))s"))
    vm.stopPolling()
    return out
}

/// Finding: a dropped socket never reached the poll loop.
@MainActor func pollingTightensWhenSocketDrops() async -> [Check] {
    let s = "socket drops"
    var out: [Check] = []
    let pk = 9104
    let (vm, socket) = await healthyPushGame(pk, batter: 6131, pitcher: 6230)
    out.append(Check(scenario: s, name: "(setup) polling had backed off to 60s behind a healthy socket",
                     ok: vm.debugInfo.pollingInterval == 60, detail: "\(Int(vm.debugInfo.pollingInterval))s"))
    let mark = Date()
    await socket?.send(.disconnected(reason: "simulated drop"))
    await pause(12)
    let polls = await api.hits("feed:\(pk)").filter { $0.at > mark }.count
    out.append(Check(scenario: s, name: "polling takes over within seconds of the socket dropping",
                     ok: polls >= 2, detail: "\(polls) polls in the next 12s · interval now \(Int(vm.debugInfo.pollingInterval))s"))
    vm.stopPolling()
    return out
}

/// Finding: every socket update during a break restarted the loop and
/// downloaded the whole feed.
@MainActor func breakCountdownDoesNotRestartPolling() async -> [Check] {
    let s = "break countdown"
    var out: [Check] = []
    let pk = 9105
    await api.pin(gamePk: pk, feed: feed(Spec(seq: 0, inning: 4, outs: 2, atBat: 70, batter: 6141, pitcher: 6240)))
    let vm = GameViewModel(gamePk: pk, venueName: "Sim Park")
    vm.startPolling()
    let socket = await waitForSocket(pk)
    await pause(1)
    await socket?.send(.opened)
    // The half-inning ends: the socket says so, and polls now see the same.
    await api.pin(gamePk: pk, feed: feed(Spec(seq: 20, inning: 4, half: "Middle", outs: 3, atBat: 70, batter: 6141, pitcher: 6240)))
    await api.queueDiffs(gamePk: pk, [.success(patch([replace("/liveData/linescore/inningState", "\"Middle\"")], seq: 20))])
    await socket?.send(.update(GamedayPushEvent(updateId: "third-out")))
    await pause(6)   // the loop's own poll at ~5s puts it to sleep for the rest of the break
    out.append(Check(scenario: s, name: "(setup) break card up and the loop asleep until the break ends",
                     ok: stateName(vm).hasPrefix("break") && vm.debugInfo.pollingInterval > 100,
                     detail: "\(stateName(vm)) · \(Int(vm.debugInfo.pollingInterval))s"))
    let mark = Date()
    for i in 1...3 {
        await api.queueDiffs(gamePk: pk, [.success(patch([replace("/liveData/linescore/balls", "0")], seq: 20 + i))])
        await socket?.send(.update(GamedayPushEvent(updateId: "quiet\(i)")))
        await pause(2)
    }
    await pause(2)
    let polls = await api.hits("feed:\(pk)").filter { $0.at > mark }.count
    let applied = vm.debugInfo.push?.updatesApplied ?? -1
    out.append(Check(scenario: s, name: "three socket updates during the break cause no re-download",
                     ok: polls == 0 && applied == 4, detail: "\(polls) polls · \(applied) patches applied"))
    vm.stopPolling()
    return out
}

/// Finding: every break from the last scheduled inning on was polled every 5s.
@MainActor func lateBreakLeansOnHealthySocket() async -> [Check] {
    let s = "late-inning break"
    var out: [Check] = []
    let pk = 9106
    let (vm, socket) = await healthyPushGame(pk, batter: 6151, pitcher: 6250, inning: 9, home: 2, away: 3)
    out.append(Check(scenario: s, name: "(setup) polling had backed off to 60s behind a healthy socket",
                     ok: vm.debugInfo.pollingInterval == 60, detail: "\(Int(vm.debugInfo.pollingInterval))s"))
    // Middle of the 9th, home team behind: the game goes on.
    await api.pin(gamePk: pk, feed: feed(Spec(seq: 20, inning: 9, half: "Middle", outs: 3, atBat: 60, batter: 6151, pitcher: 6250, home: 2, away: 3)))
    await api.queueDiffs(gamePk: pk, [.success(patch([replace("/liveData/linescore/inningState", "\"Middle\"")], seq: 20))])
    let mark = Date()
    await socket?.send(.update(GamedayPushEvent(updateId: "third-out")))
    await pause(16)
    let polls = await api.hits("feed:\(pk)").filter { $0.at > mark }.count
    out.append(Check(scenario: s, name: "middle of the 9th with the socket healthy is not re-downloaded every 5s",
                     ok: stateName(vm).hasPrefix("break") && polls == 0,
                     detail: "\(stateName(vm)) · \(polls) polls in 16s"))
    vm.stopPolling()
    return out
}

// MARK: - Runner

@main
struct Sim {
    static func main() async {
        var all: [Check] = []

        FeatureFlags.pushFeedEnabled = false
        async let a = alwaysFailingRequest()
        async let b = droppedRequestRecovers()
        async let c = situationUpdatesDespiteFailure()
        async let d = normalAtBats()
        async let e = cancelledRefreshIsRedone()
        all += await a + b + c + d + e

        FeatureFlags.pushFeedEnabled = true
        async let f = killSwitchTripsDespiteEmptyAnswers()
        async let g = unansweredRequestsDoNotCount()
        async let h = pollingRestartsWhenPushShutsOff()
        async let i = pollingTightensWhenSocketDrops()
        async let j = breakCountdownDoesNotRestartPolling()
        async let k = lateBreakLeansOnHealthySocket()
        all += await f + g + h + i + j + k

        var last = ""
        for check in all {
            if check.scenario != last { print("\n[\(check.scenario)]"); last = check.scenario }
            print("  \(check.ok ? "PASS" : "FAIL")  \(check.name)  —  \(check.detail)")
        }
        let failed = all.filter { !$0.ok }.count
        print("\n\(all.count - failed) of \(all.count) checks passed")
        exit(failed == 0 ? 0 : 1)
    }
}
