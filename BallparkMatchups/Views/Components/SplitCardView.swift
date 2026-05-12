import SwiftUI

struct SplitCardView: View {
    let split: SplitLine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(split.label.uppercased())
                    .labelFont(size: 11)
                    .kerning(1.2)
                Spacer()
                Text(split.scope)
                    .labelFont(size: 11)
            }

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(split.avg) / \(split.obp) / \(split.slg)")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.primaryText)
                    .monospacedDigit()

                Spacer()

                Text("(\(split.pa) PA)")
                    .labelFont(size: 12)
            }

            Divider().background(Color(hex: "#222222"))
        }
    }
}
