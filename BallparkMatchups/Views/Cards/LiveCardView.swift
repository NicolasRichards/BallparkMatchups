import SwiftUI

struct LiveCardView: View {
    let card: MatchupCard

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SituationStripView(situation: card.situation)
            MatchupBlockView(
                batter: card.batter,
                pitcher: card.pitcher,
                batterGame: card.batterGame,
                pitcherGame: card.pitcherGame
            )

            if let bvp = card.bvp {
                BvPCardView(bvp: bvp)
            }

            if !card.batterSplits.isEmpty {
                BatterSplitsGroupView(splits: card.batterSplits)
            }

            if let pitcherSplit = card.pitcherSplit {
                SplitCardView(split: pitcherSplit)
            }

            if let event = card.lastEvent {
                LastEventView(text: event)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: card.situation.displayInning)
    }
}

struct LastEventView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(Color(hex: "#2A3A2A"))
                .frame(height: 1)

            HStack(alignment: .top, spacing: 6) {
                Text("LAST PLAY")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .kerning(1.2)
                    .padding(.top, 1)

                Text(text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Theme.primaryText.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
