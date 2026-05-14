import SwiftUI

struct GameView: View {
    @ObservedObject var vm: GameViewModel
    @EnvironmentObject private var app: AppViewModel
    @State private var showDebug = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    topBar
                    connectionBanner
                    cardContent
                    Spacer(minLength: 60)
                }
            }

            if showDebug {
                DebugOverlayView(info: vm.debugInfo)
                    .transition(.opacity)
            }
        }
        .gesture(
            LongPressGesture(minimumDuration: 1.5)
                .onEnded { _ in withAnimation { showDebug.toggle() } }
        )
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                app.leaveGame()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
            }

            if let score = vm.scoreDisplay {
                Text("\(score.awayAbbr) \(score.awayScore)  \(score.homeAbbr) \(score.homeScore)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.primaryText)
                    .padding(.leading, 14)
            }

            Spacer()

            if let updated = vm.lastUpdated {
                LastUpdatedText(date: updated, status: vm.connectionStatus)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .padding(.top, 44)
    }

    // MARK: - Connection Banner

    @ViewBuilder
    private var connectionBanner: some View {
        switch vm.connectionStatus {
        case .ok:
            EmptyView()
        case .retrying(_, let failures):
            if failures >= 3 {
                ConnectionBanner(text: "Reconnecting…")
            }
        case .degraded:
            ConnectionBanner(text: "Connection issues", showRetry: true) {
                vm.handleForeground()
            }
        }
    }

    // MARK: - Card Content

    @ViewBuilder
    private var cardContent: some View {
        switch vm.uiState {
        case .loading:
            ProgressView()
                .tint(Theme.secondaryText)
                .padding(.top, 80)

        case .preGame(let info):
            PreGameCardView(info: info)
                .padding(.top, 16)

        case .live(let card):
            LiveCardView(card: card)
                .padding(.horizontal, 20)
                .padding(.top, 8)

        case .betweenInnings(let info):
            BetweenInningsCardView(info: info)
                .padding(.top, 16)

        case .delay(let info):
            DelayCardView(info: info)
                .padding(.top, 16)

        case .suspended:
            SimpleStatusView(title: "GAME SUSPENDED", detail: "Game paused.")
                .padding(.top, 16)

        case .final_(let info):
            FinalCardView(info: info)
                .padding(.top, 16)

        case .postponed(let reason):
            PostponedView(reason: reason)
                .padding(.top, 16)
        }
    }
}

// MARK: - Last Updated Text

struct LastUpdatedText: View {
    let date: Date
    let status: ConnectionStatus
    @State private var now = Date()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let seconds = Int(now.timeIntervalSince(date))
        Text(seconds < 5 ? "Live" : "Updated \(seconds)s ago")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(statusColor(seconds: seconds))
            .onReceive(timer) { now = $0 }
    }

    private func statusColor(seconds: Int) -> Color {
        switch status {
        case .ok: return seconds > 30 ? .yellow : Theme.secondaryText
        case .retrying: return .yellow
        case .degraded: return .red
        }
    }
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    let text: String
    var showRetry = false
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.yellow)

            if showRetry, let onRetry {
                Spacer()
                Button("Retry", action: onRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.yellow)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.12))
        .animation(.easeInOut, value: text)
    }
}

// MARK: - Simple Status Views

struct SimpleStatusView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .primaryFont(size: 20, weight: .bold)
            Text(detail)
                .labelFont(size: 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

struct PostponedView: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TONIGHT'S GAME POSTPONED")
                .primaryFont(size: 20, weight: .bold)
            Text("Game was postponed\(reason.isEmpty ? "." : " due to \(reason.lowercased()).")")
                .labelFont(size: 15)
            Text("Make-up: TBA")
                .labelFont(size: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}
