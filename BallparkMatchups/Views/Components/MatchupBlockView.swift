import SwiftUI

struct MatchupBlockView: View {
    let batter: PlayerInfo
    let pitcher: PlayerInfo

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
        VStack(alignment: .leading, spacing: 5) {
            // Name + position + handedness
            HStack(alignment: .firstTextBaseline, spacing: 10) {
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

            // Age · Height · Weight · Team
            HStack(spacing: 8) {
                if let age = player.ageString {
                    metaChip(age)
                    Text("·").labelFont(size: 13)
                }
                if let h = player.heightString {
                    metaChip(h)
                    Text("·").labelFont(size: 13)
                }
                if let w = player.weightLbs {
                    metaChip("\(w)")
                    if let abbr = player.teamAbbreviation {
                        Text("·").labelFont(size: 13)
                        Text(abbr)
                            .labelFont(size: 13)
                    }
                }
            }
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .labelFont(size: 13)
    }
}
