import SwiftUI

struct PreGameCardView: View {
    let info: PreGameInfo
    @State private var countdown = ""
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Venue
            Text(info.venueName.uppercased())
                .labelFont(size: 11)
                .kerning(1.5)

            // Teams
            VStack(alignment: .leading, spacing: 4) {
                Text("\(info.awayTeam) vs \(info.homeTeam)")
                    .primaryFont(size: 22, weight: .bold)
            }

            // First pitch
            if let fp = info.firstPitch {
                Text("First pitch \(formatTime(fp))\(countdown.isEmpty ? "" : " (\(countdown))")")
                    .labelFont(size: 15)
            }

            Divider().background(Color(hex: "#222222"))

            // Pitchers
            VStack(alignment: .leading, spacing: 10) {
                pitcherLine(
                    team: info.homeTeam,
                    name: info.homePitcher,
                    hand: info.homeHand
                )
                pitcherLine(
                    team: info.awayTeam,
                    name: info.awayPitcher,
                    hand: info.awayHand
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .onAppear { updateCountdown() }
        .onReceive(timer) { _ in updateCountdown() }
    }

    private func pitcherLine(team: String, name: String?, hand: String?) -> some View {
        HStack(spacing: 6) {
            Text(team + ":")
                .labelFont(size: 14)
            Text(name ?? "TBA")
                .primaryFont(size: 15, weight: .semibold)
            if let hand {
                Text("(\(hand))")
                    .labelFont(size: 13)
            }
        }
    }

    private func updateCountdown() {
        guard let fp = info.firstPitch else { countdown = ""; return }
        let mins = Int(fp.timeIntervalSinceNow / 60)
        if mins <= 0 { countdown = ""; return }
        if mins < 60 {
            countdown = "in \(mins)m"
        } else {
            let h = mins / 60, m = mins % 60
            countdown = m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = .current
        return f.string(from: date)
    }
}
