import Foundation

// MARK: - Split Priority Engine (§10)

struct SplitPriorityEngine {

    // sitCodes to always request for batters, filtered/ranked client-side
    static let batterSitCodes: [String] = [
        "r123", "r3l2", "risp2", "risp", "ron2", "lc",
        "c30", "c02", "c32", "vl", "vr", "2s", "o2"
    ]

    // Career stats baseline sitCodes
    static let careerBaselineSitCodes: [String] = [
        "r123", "risp2", "risp", "ron2", "lc", "vl", "vr", "2s"
    ]

    // sitCodes to request for pitchers
    static let pitcherSitCodes: [String] = [
        "risp", "risp2", "lc", "vl", "vr", "fba",
        "pi076", "pi091", "pi106", "pi121"
    ]

    // MARK: - Batter Split Selection (§10.4)

    static func selectBatterSplits(
        tickState: TickState,
        splits: [SplitLine],
        careerOPS: Double?,
        maxCount: Int = 3
    ) -> [SplitLine] {
        let runners = RunnersState.from(
            onFirst: tickState.runnersCode.contains("1"),
            onSecond: tickState.runnersCode.contains("2"),
            onThird: tickState.runnersCode.contains("3")
        )
        let outs = tickState.outs
        let balls = tickState.balls
        let strikes = tickState.strikes
        let inning = tickState.halfInning
        let isLate = inning >= 7

        // Determine score delta for lc (late & close = within 3 runs)
        // We don't have score here; include lc candidates and let caller filter
        // Build ordered priority list of sitCodes to try
        var candidates: [String] = []

        if runners.isLoaded { candidates.append("r123") }
        if runners.hasThirdLessThanTwo && outs < 2 { candidates.append("r3l2") }
        if runners.hasScoringPosition && outs == 2 { candidates.append("risp2") }
        if runners.hasScoringPosition { candidates.append("risp") }
        if runners.hasRunners && outs == 2 { candidates.append("ron2") }
        if isLate { candidates.append("lc") }

        let leverageCount = "\(balls)\(strikes)"
        if ["30", "02", "32"].contains(leverageCount) {
            candidates.append("c\(leverageCount)")
        }

        candidates.append("vl")
        candidates.append("vr")

        if strikes == 2 { candidates.append("2s") }

        // Map candidates to actual split lines (prefer career, then season)
        var selected: [SplitLine] = []
        let splitMap = Dictionary(grouping: splits, by: \.sitCode)

        for code in candidates {
            guard selected.count < maxCount else { break }
            if let lines = splitMap[code], let best = lines.sorted(by: { $0.scope > $1.scope }).first {
                selected.append(best)
            }
        }

        // §10.5 Information-gain filter: drop splits within 30 OPS points of career OPS
        if let careerOPS {
            selected = selected.filter { split in
                abs(split.ops - careerOPS) >= 0.030
            }
        }

        return Array(selected.prefix(maxCount))
    }

    // MARK: - Pitcher Split Selection (§10.4 pitcher-side)

    static func selectPitcherSplit(
        tickState: TickState,
        splits: [SplitLine],
        currentPitchCount: Int?,
        isReliever: Bool,
        isFirstBatter: Bool,
        careerOPS: Double?
    ) -> SplitLine? {
        let runners = RunnersState.from(
            onFirst: tickState.runnersCode.contains("1"),
            onSecond: tickState.runnersCode.contains("2"),
            onThird: tickState.runnersCode.contains("3")
        )
        let inning = tickState.halfInning
        let isLate = inning >= 7
        let splitMap = Dictionary(grouping: splits, by: \.sitCode)

        func best(_ code: String) -> SplitLine? {
            splitMap[code]?.sorted(by: { $0.scope > $1.scope }).first
        }

        if isReliever && isFirstBatter, let s = best("fba") { return s }

        if let count = currentPitchCount, count > 75 {
            let bucket: String
            switch count {
            case 76...90: bucket = "pi076"
            case 91...105: bucket = "pi091"
            case 106...120: bucket = "pi106"
            default: bucket = "pi121"
            }
            if let s = best(bucket) { return s }
        }

        if runners.hasScoringPosition, let s = best("risp") { return s }
        if isLate, let s = best("lc") { return s }

        // Handedness fallback
        if let s = best("vl") ?? best("vr") { return s }

        return nil
    }

    // MARK: - PA Thresholds (§10.3)

    static func passesBatterThreshold(pa: Int, isCareer: Bool) -> Bool {
        isCareer ? pa >= 25 : pa >= 15
    }

    // MARK: - sitCode Labels

    static func label(for code: String) -> String {
        let labels: [String: String] = [
            "r0": "Bases Empty",
            "r1": "Runner on 1st",
            "r2": "Runner on 2nd",
            "r3": "Runner on 3rd",
            "r12": "1st & 2nd",
            "r13": "1st & 3rd",
            "r23": "2nd & 3rd",
            "r123": "Bases Loaded",
            "risp": "RISP",
            "risp2": "RISP, 2 Out",
            "ron2": "Runners On, 2 Out",
            "r3l2": "Runner on 3rd, < 2 Out",
            "lc": "Late & Close",
            "c00": "Count 0-0",
            "c30": "Count 3-0",
            "c02": "Count 0-2",
            "c32": "Full Count",
            "2s": "Two Strikes",
            "vl": "vs Left",
            "vr": "vs Right",
            "fba": "First Batter (RP)",
            "pi076": "Pitch 76–90",
            "pi091": "Pitch 91–105",
            "pi106": "Pitch 106–120",
            "pi121": "Pitch 121+",
            "h": "Home",
            "a": "Away",
            "d": "Day Game",
            "n": "Night Game",
        ]
        return labels[code] ?? code.uppercased()
    }
}

// MARK: - Stats Parsing Helpers

extension StatsResponse {
    func toBvPLine() -> BvPLine? {
        guard let split = stats.first?.splits.first else { return nil }
        let stat = split.stat
        guard let pa = stat.plateAppearances, pa > 0 else { return nil }
        let opsDouble = stat.ops.flatMap { Double($0) }
        return BvPLine(
            pa: pa,
            avg: stat.avg ?? ".---",
            obp: stat.obp ?? ".---",
            slg: stat.slg ?? ".---",
            ops: opsDouble,
            hr: stat.homeRuns ?? 0,
            so: stat.strikeOuts ?? 0,
            bb: stat.baseOnBalls ?? 0
        )
    }

    func toSplitLines(scope: String, minPA: Int) -> [SplitLine] {
        var result: [SplitLine] = []
        for group in stats {
            for entry in group.splits {
                guard
                    let code = entry.split?.code,
                    let pa = entry.stat.plateAppearances,
                    pa >= minPA,
                    let avg = entry.stat.avg,
                    let obp = entry.stat.obp,
                    let slg = entry.stat.slg
                else { continue }
                let opsVal = entry.stat.ops.flatMap { Double($0) } ?? {
                    let o = (Double(obp) ?? 0) + (Double(slg) ?? 0)
                    return o > 0 ? o : 0
                }()
                let line = SplitLine(
                    sitCode: code,
                    label: SplitPriorityEngine.label(for: code),
                    scope: scope,
                    pa: pa,
                    avg: avg,
                    obp: obp,
                    slg: slg,
                    ops: opsVal
                )
                result.append(line)
            }
        }
        return result
    }
}
