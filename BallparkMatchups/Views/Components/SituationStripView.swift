import SwiftUI

struct SituationStripView: View {
    let situation: SituationStrip

    var body: some View {
        HStack(spacing: 0) {
            group(situation.displayInning)
            separator
            group(situation.outsDisplay)
            separator
            group(situation.runnersDisplay)
            separator
            group("\(situation.balls)-\(situation.strikes)")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.situationBackground)
    }

    private func group(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.primaryText)
            .padding(.horizontal, 6)
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 15))
            .foregroundColor(Theme.secondaryText)
    }
}
