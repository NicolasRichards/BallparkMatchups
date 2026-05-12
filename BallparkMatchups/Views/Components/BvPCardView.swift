import SwiftUI

struct BvPCardView: View {
    let bvp: BvPLine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BATTER vs PITCHER (career)")
                .labelFont(size: 11)
                .kerning(1.5)

            content

            Divider().background(Color(hex: "#222222"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if bvp.pa >= 6 {
            fullSlashLine
        } else if bvp.pa >= 1 {
            limitedHistory
        } else {
            Text("First career meeting")
                .labelFont(size: 15)
        }
    }

    private var fullSlashLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(bvp.avg) / \(bvp.obp) / \(bvp.slg)")
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.primaryText)
                .monospacedDigit()

            HStack(spacing: 12) {
                statPair("\(bvp.pa) PA")
                statPair("\(bvp.hr) HR")
                statPair("\(bvp.so) K")
                statPair("\(bvp.bb) BB")
            }
        }
    }

    private var limitedHistory: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Limited history (\(bvp.pa) PA): \(bvp.rawLine)")
                .primaryFont(size: 15)
        }
    }

    private func statPair(_ text: String) -> some View {
        Text(text)
            .statFont(size: 14)
            .foregroundColor(Theme.secondaryText)
    }
}
