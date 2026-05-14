import SwiftUI

struct MatchupBlockView: View {
    let batter: PlayerInfo
    let pitcher: PlayerInfo
    let batterGame: BatterGameLine?
    let pitcherGame: PitcherGameLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            playerBlock(player: batter, role: .batter)
            Text("vs.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.secondaryText)
                .padding(.leading, 2)
            playerBlock(player: pitcher, role: .pitcher)
        }
    }

    private enum Role { case batter, pitcher }

    private func playerBlock(player: PlayerInfo, role: Role) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Role label
            Text(role == .batter ? "BATTER" : "PITCHER")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .kerning(1.2)

            // Name · position · handedness
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(player.fullName.uppercased())
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(Theme.primaryText)

                Text("·")
                    .labelFont(size: 16)

                Text(player.primaryPosition)
                    .labelFont(size: 15)

                Text("·")
                    .labelFont(size: 16)

                if role == .batter, let side = player.batSide {
                    Text(side.displayCode)
                        .labelFont(size: 15)
                } else if role == .pitcher, let hand = player.pitchHand {
                    Text("\(hand.displayCode)HP")
                        .labelFont(size: 15)
                }
            }

            // Game stats
            if role == .batter, let g = batterGame {
                Text(g.display)
                    .statFont(size: 14)
                    .foregroundColor(Theme.secondaryText)
                    .padding(.top, 1)
            } else if role == .pitcher, let g = pitcherGame {
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.pitchLine)
                        .statFont(size: 14)
                        .foregroundColor(Theme.secondaryText)
                    Text(g.statLine)
                        .statFont(size: 14)
                        .foregroundColor(Theme.secondaryText)
                }
                .padding(.top, 1)
            }
        }
    }
}
