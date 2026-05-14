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
        }
        .animation(.easeInOut(duration: 0.2), value: card.situation.displayInning)
    }
}
