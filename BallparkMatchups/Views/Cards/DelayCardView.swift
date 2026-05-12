import SwiftUI

struct DelayCardView: View {
    let info: DelayInfo

    private var title: String {
        let reason = info.reason
            .replacingOccurrences(of: "Delayed:", with: "")
            .replacingOccurrences(of: "Delayed Start", with: "")
            .trimmingCharacters(in: .whitespaces)
        if reason.isEmpty { return "DELAY" }
        return "\(reason.uppercased()) DELAY"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .primaryFont(size: 22, weight: .bold)

            Text(info.isPreGame ? "First pitch postponed." : "Game paused.")
                .labelFont(size: 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}
