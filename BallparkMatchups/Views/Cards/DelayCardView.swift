import SwiftUI

struct DelayCardView: View {
    let info: DelayInfo

    /// "Delayed: Rain" and "Delayed Start: Rain" both become "RAIN DELAY".
    /// Everything up to the colon is the state; what follows is the cause.
    private var title: String {
        let reason = info.reason
            .split(separator: ":", maxSplits: 1)
            .dropFirst()
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if reason.isEmpty { return "DELAY" }
        // The one reason that isn't a cause
        if reason == "About to Resume" { return "ABOUT TO RESUME" }
        return "\(reason.uppercased()) DELAY"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .primaryFont(size: 22, weight: .bold)

            Text(info.isPreGame ? "First pitch delayed." : "Game paused.")
                .labelFont(size: 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}
