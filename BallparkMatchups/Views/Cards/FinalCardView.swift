import SwiftUI

struct FinalCardView: View {
    let info: FinalInfo

    private var winnerScore: Int {
        info.homeScore > info.awayScore ? info.homeScore : info.awayScore
    }
    private var loserScore: Int {
        info.homeScore > info.awayScore ? info.awayScore : info.homeScore
    }
    private var winnerTeam: String {
        info.homeScore > info.awayScore ? info.homeTeam : info.awayTeam
    }
    private var loserTeam: String {
        info.homeScore > info.awayScore ? info.awayTeam : info.homeTeam
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("FINAL")
                .primaryFont(size: 13, weight: .semibold)
                .foregroundColor(Theme.secondaryText)
                .kerning(1.5)

            Text("\(winnerTeam) \(winnerScore), \(loserTeam) \(loserScore)")
                .primaryFont(size: 26, weight: .bold)
                .monospacedDigit()

            if info.winnerName != nil || info.loserName != nil {
                Divider().background(Color(hex: "#222222"))

                VStack(alignment: .leading, spacing: 8) {
                    if let w = info.winnerName {
                        decisionLine(label: "W", name: w)
                    }
                    if let l = info.loserName {
                        decisionLine(label: "L", name: l)
                    }
                    if let s = info.saveName {
                        decisionLine(label: "SV", name: s)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func decisionLine(label: String, name: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .statFont(size: 13)
                .foregroundColor(Theme.secondaryText)
                .frame(width: 22, alignment: .leading)
            Text(name)
                .primaryFont(size: 15)
        }
    }
}
