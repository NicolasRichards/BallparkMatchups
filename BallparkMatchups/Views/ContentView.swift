import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppViewModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
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
