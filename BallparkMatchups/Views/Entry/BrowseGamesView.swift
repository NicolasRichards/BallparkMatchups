import SwiftUI

struct BrowseGamesView: View {
    @EnvironmentObject private var app: AppViewModel
    @State private var filter: GameFilter = .mlb

    enum GameFilter: String, CaseIterable {
        case mlb = "MLB"
        case milb = "MiLB"
        case live = "Live"
        case all = "All"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            filterBar
            gameList
        }
        .background(Theme.background)
        .task { await app.loadBrowseGames() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button {
                app.state = .entry
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
            }

            Spacer()

            Text("TODAY'S GAMES")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .kerning(1.5)

            Spacer()

            Button {
                Task { await app.loadBrowseGames() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.primaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .padding(.top, 44)
    }

    // MARK: - Filter

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GameFilter.allCases, id: \.self) { f in
                    filterChip(f)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func filterChip(_ f: GameFilter) -> some View {
        Button {
            filter = f
        } label: {
            Text(f.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(filter == f ? Theme.primaryText : Theme.situationBackground)
                .foregroundColor(filter == f ? .black : Theme.secondaryText)
        }
    }

    // MARK: - Game List

    private var gameList: some View {
        Group {
            if app.browseLoading {
                ProgressView()
                    .tint(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        let grouped = groupedGames()
                        ForEach(grouped, id: \.bucket) { section in
                            Section {
                                ForEach(section.games) { game in
                                    GameRow(game: game) {
                                        Task { await app.selectGame(game) }
                                    }
                                    Divider()
                                        .background(Color(hex: "#222222"))
                                        .padding(.leading, 20)
                                }
                            } header: {
                                bucketHeader(section.bucket)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bucketHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.secondaryText)
            .kerning(1.5)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background)
    }

    private struct BucketSection {
        let bucket: String
        let games: [GameSummary]
    }

    private func groupedGames() -> [BucketSection] {
        let filtered = app.browseGames.filter { game in
            switch filter {
            case .all: return true
            case .live: return game.detailedState == "In Progress"
            case .mlb: return !game.isMiLB
            case .milb: return game.isMiLB
            }
        }

        let bucketOrder = ["LIVE NOW", "STARTING SOON", "LATER TODAY", "FINAL"]
        var dict: [String: [GameSummary]] = [:]
        for game in filtered {
            let bucket = game.bucketLabel
            dict[bucket, default: []].append(game)
        }
        return bucketOrder.compactMap { bucket in
            guard let games = dict[bucket], !games.isEmpty else { return nil }
            let sorted = games.sorted { $0.gameDate < $1.gameDate }
            return BucketSection(bucket: bucket, games: sorted)
        }
    }
}

// MARK: - Game Row

struct GameRow: View {
    let game: GameSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(game.awayAbbr)
                            .primaryFont(size: 16)
                        Text("at")
                            .labelFont(size: 14)
                        Text(game.homeAbbr)
                            .primaryFont(size: 16)

                        if game.sportId != 1, let level = game.sportLevel {
                            Text(level.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.situationBackground)
                        }
                    }

                    if let score = game.scoreDisplay {
                        Text(score)
                            .statFont(size: 14)
                            .foregroundColor(Theme.secondaryText)
                    } else {
                        Text(game.venueName)
                            .labelFont(size: 13)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(game.statusDisplay)
                        .statFont(size: 14, bold: game.detailedState == "In Progress")
                        .foregroundColor(game.detailedState == "In Progress" ? Theme.primaryText : Theme.secondaryText)

                    if game.detailedState != "In Progress" && game.detailedState != "Final" {
                        Text(formatTime(game.gameDate))
                            .labelFont(size: 12)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
