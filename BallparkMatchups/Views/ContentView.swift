import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Every screen is one narrow column of cards. Unbounded it spans the full
    /// width of an iPad, so cap it and let the ZStack centre it.
    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 700 : .infinity
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
                .frame(maxWidth: contentMaxWidth)
        }
        .preferredColorScheme(.dark)
        .task { await app.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            app.handleForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            app.handleBackground()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.state {
        case .loading:
            LaunchSplashView()

        case .entry:
            EntryView()
                .environmentObject(app)

        case .locating:
            LocatingView()

        case .browseGames:
            BrowseGamesView()
                .environmentObject(app)

        case .loadingGame:
            LoadingGameView()

        case .game:
            if let gameVM = app.gameVM {
                GameView(vm: gameVM)
                    .environmentObject(app)
            }

        case .locationDenied:
            LocationDeniedView()
                .environmentObject(app)

        case .locationFailed:
            LocationFailedView()
                .environmentObject(app)

        case .notAtBallpark:
            NotAtBallparkView()
                .environmentObject(app)
        }
    }
}

// MARK: - Utility Loading Views

struct LaunchSplashView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BALLPARK\nMATCHUPS")
                .font(.system(size: 34, weight: .black))
                .foregroundColor(Theme.primaryText)
                .lineSpacing(4)
            ProgressView()
                .tint(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 100)
    }
}

struct LocatingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .tint(Theme.secondaryText)
            Text("Detecting location…")
                .labelFont()
        }
    }
}

struct LoadingGameView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .tint(Theme.secondaryText)
            Text("Loading game…")
                .labelFont()
        }
    }
}
