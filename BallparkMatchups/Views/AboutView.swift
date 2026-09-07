import SwiftUI
import StoreKit

/// About / support screen, reached from the info button on the entry screen.
///
/// Mirrors the tip jar in the movie apps (ReelRankings / WeeklyMovies), restyled
/// to this app's dark theme, with baseball wording and a `baseball` tier icon in
/// place of `movieclapper` — that symbol needs iOS 18 and this app ships back to
/// iOS 17.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    private let tipJar = TipJar.shared

    private let appStoreURL = URL(string: "https://apps.apple.com/app/id6770288002")!

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BALLPARK\nMATCHUPS")
                            .font(.system(size: 34, weight: .black))
                            .foregroundColor(Theme.primaryText)
                            .lineSpacing(4)
                        Text("Live batter vs. pitcher data.")
                            .labelFont(size: 15)
                    }
                    .padding(.top, 32)

                    supportSection

                    Text("Made with love by Nicolas Richards")
                        .labelFont(size: 12)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button("Done") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
        .task { await tipJar.load() }
    }

    // MARK: - Support

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ENJOYING THE APP? ⚾️")
                .primaryFont(size: 16, weight: .bold)
                .kerning(1.2)

            Text("This app is 100% free, ad-free and tracking free, a gift meant for every baseball fan. Have a little extra and want to say thanks? Only do this if you really can afford to!")
                .labelFont(size: 14)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("☕ BUY US A COFFEE?")
                    .primaryFont(size: 13, weight: .bold)
                    .kerning(1.5)

                if tipJar.didTip {
                    Text("Thank you so much. 💛")
                        .primaryFont(size: 15)
                        .padding(.vertical, 8)
                } else if tipJar.loadFailed {
                    Text("Tip options couldn't load right now.")
                        .labelFont(size: 13)
                        .padding(.vertical, 8)
                } else if tipJar.products.isEmpty {
                    ProgressView()
                        .tint(Theme.secondaryText)
                        .padding(.vertical, 12)
                } else {
                    ForEach(tipJar.products, id: \.id) { product in
                        tipRow(balls: ballCount(for: product), product: product)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.situationBackground)
            .overlay(Rectangle().stroke(Color(hex: "#333333"), lineWidth: 1))

            HStack(spacing: 12) {
                Button {
                    requestReview()
                } label: {
                    Label("Rate us", systemImage: "star.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.primaryText)
                        .foregroundColor(.black)
                }

                Button {
                    openURL(appStoreURL)
                } label: {
                    Label("App Store", systemImage: "arrow.up.forward")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.situationBackground)
                        .foregroundColor(Theme.primaryText)
                        .overlay(Rectangle().stroke(Color(hex: "#333333"), lineWidth: 1))
                }
            }
        }
    }

    private func tipRow(balls: Int, product: Product) -> some View {
        Button {
            Task { await tipJar.purchase(product) }
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    ForEach(0..<balls, id: \.self) { _ in
                        Image(systemName: "baseball")
                    }
                }
                .foregroundColor(Theme.primaryText)

                Text(tierName(for: balls))
                    .primaryFont(size: 16)

                Spacer()

                if tipJar.purchasing == product.id {
                    ProgressView().tint(Theme.secondaryText)
                } else {
                    Text(product.displayPrice)
                        .statFont(size: 16, bold: true)
                        .foregroundColor(Theme.primaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Theme.cardBackground)
            .overlay(Rectangle().stroke(Color(hex: "#333333"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(tipJar.purchasing != nil)
    }

    private func tierName(for balls: Int) -> String {
        switch balls {
        case 1: "Small tip"
        case 2: "Medium tip"
        default: "Large tip"
        }
    }

    /// Ball count keyed off the product's own ID, not its position in a
    /// price-sorted list — that list can have fewer than 3 entries whenever
    /// not every tier is approved yet, which would otherwise mislabel tiers.
    private func ballCount(for product: Product) -> Int {
        if product.id.hasSuffix(".small") { return 1 }
        if product.id.hasSuffix(".medium") { return 2 }
        return 3
    }
}
