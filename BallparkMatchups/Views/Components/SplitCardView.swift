import SwiftUI

// MARK: - Grouped batter splits (rounded rectangle with year header)

struct BatterSplitsGroupView: View {
    let splits: [SplitLine]

    // Rows can mix career and season splits; only show a scope in the header
    // when it applies to every row, otherwise label each row individually.
    private var uniformScope: String? {
        let scopes = Set(splits.map(\.scope))
        return scopes.count == 1 ? scopes.first : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row: label + scope (when uniform)
            HStack {
                Text("BATTER SPLITS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .kerning(1.2)
                Spacer()
                Text(uniformScope ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color(hex: "#2A3A2A"))

            ForEach(splits.indices, id: \.self) { i in
                splitRow(splits[i])
                if i < splits.count - 1 {
                    Rectangle()
                        .fill(Color(hex: "#222222"))
                        .frame(height: 1)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func splitRow(_ split: SplitLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(split.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .kerning(1.2)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(split.avg) / \(split.obp) / \(split.slg)")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.primaryText)
                    .monospacedDigit()

                Spacer()

                Text(uniformScope == nil ? "(\(split.pa) PA · \(split.scope))" : "(\(split.pa) PA)")
                    .labelFont(size: 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Standalone pitcher split card (unchanged style)

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
