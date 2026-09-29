import Foundation
import SwiftUI
import CoreLocation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var state: AppState = .loading
    @Published var gameVM: GameViewModel?
    @Published var browseGames: [GameSummary] = []
    @Published var browseLoading = false
    /// The last attempt to load the game list failed.
    @Published var browseLoadFailed = false
    @Published var disambiguationVenues: [CachedVenue] = []
    @Published var noGameVenue: CachedVenue?
    @Published var nextHomeGame: GameSummary?
    @Published var locationVenue: CachedVenue?

    private let location = LocationService.shared
    private let venueCache = VenueCache.shared
    private let api = MLBAPIClient.shared
    private let sessionKey = "activeSession_v1"
    private var gameStateObserver: AnyCancellable?
    private var gameReturnState: AppState = .entry

    // MARK: - Boot

    func onAppear() async {
        // Load the venue cache first: session restore looks the saved venue up
        // in it, and loading is local and quick. A background load let the
        // lookup run first against an empty list. The network refresh can
        // wait.
        await venueCache.load()
        Task { await venueCache.reloadIfNeeded() }
        await restoreSessionIfValid()
        // If session restore didn't change the state, show the entry screen.
        if case .loading = state { state = .entry }
    }

    // MARK: - Detect Location

    func detectLocation() async {
        clearVenueResults()
        state = .locating
        let result = await location.requestLocation()
        switch result {
        case .success(let coord):
            let matches = await venueCache.match(coordinate: coord)
            switch matches.count {
            case 0:
                state = .notAtBallpark
            case 1:
                await resolveVenue(matches[0])
            default:
                disambiguationVenues = matches
                // Show picker — handled in UI; user calls resolveVenue()
                state = .entry
            }
        case .denied:
            state = .locationDenied
        case .failed, .timeout:
            state = .locationFailed
        }
    }

    func resolveVenue(_ venue: CachedVenue) async {
        // Keep the nearby-venue picker: if this venue has no game today, the
        // user may want the other one. It's cleared once a game opens.
        noGameVenue = nil
        nextHomeGame = nil
        locationVenue = venue
        let dateString = venue.todayDateString()
        state = .loadingGame(gamePk: 0)
        do {
            let schedule = try await api.fetchSchedule(date: dateString, venueId: venue.id)
            let games = schedule.validGames
            await selectGame(from: games, venue: venue)
        } catch {
            state = .scheduleFailed(venue)
        }
    }

    /// The start screen's results from the last detection: the nearby-venue
    /// picker and the "no game today" note. Left in place, they showed up again
    /// after a game, and a later no-game venue could show this one's next game.
    private func clearVenueResults() {
        disambiguationVenues = []
        noGameVenue = nil
        nextHomeGame = nil
    }

    // MARK: - Browse Games

    func loadBrowseGames() async {
        browseLoading = true
        defer { browseLoading = false }
        let dateString = todayDateString()
        do {
            let schedule = try await api.fetchSchedule(date: dateString)
            browseGames = schedule.validGames.compactMap { mapToSummary($0) }
            browseLoadFailed = false
        } catch {
            // Keep whatever list is up, but flag it so the screen can say it
            // is out of date instead of passing it off as current.
            browseLoadFailed = true
        }
    }

    func selectGame(_ summary: GameSummary) async {
        gameReturnState = .browseGames
        launchGame(gamePk: summary.gamePk, venueName: summary.venueName, venueId: summary.venueId)
    }

    // MARK: - Game Launch

    func launchGame(gamePk: Int, venueName: String, venueId: Int?) {
        // Guard against double-launch (e.g. rapid taps or session restore race)
        guard gameVM == nil || gameVM?.gamePk != gamePk else { return }
        gameVM?.stopPolling()
        let vm = GameViewModel(gamePk: gamePk, venueName: venueName)
        gameVM = vm
        state = .game
        disambiguationVenues = []
        vm.startPolling()
        saveSession(ActiveSession(
            gamePk: gamePk,
            // The game's own venue, not whichever one was last detected
            venueId: venueId,
            resolvedAt: Date(),
            lastKnownState: nil
        ))

        // Update lastKnownState when the game ends so session restore
        // correctly skips it on the next launch.
        gameStateObserver = vm.$uiState
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                let label: String?
                switch newState {
                case .final_:     label = "Final"
                case .postponed:  label = "Postponed"
                case .cancelled:  label = "Cancelled"
                case .suspended:  label = "Suspended"
                default:          label = nil
                }
                if let label, var session = self.loadSession() {
                    session.lastKnownState = label
                    self.saveSession(session)
                }
            }
    }

    func leaveGame() {
        gameVM?.stopPolling()
        gameVM = nil
        clearSession()
        state = gameReturnState
        gameReturnState = .entry  // reset for next time
    }

    // MARK: - Session Restore

    private func restoreSessionIfValid() async {
        guard let session = loadSession() else { return }
        let age = Date().timeIntervalSince(session.resolvedAt)
        guard age < 6 * 3600 else { clearSession(); return }
        if let last = session.lastKnownState,
           ["Final", "Game Over", "Completed Early", "Postponed", "Cancelled", "Suspended"].contains(last) {
            clearSession(); return
        }
        let venueName: String
        if let vid = session.venueId, let venue = await venueCache.venue(id: vid) {
            venueName = venue.name
            locationVenue = venue
        } else {
            venueName = "Stadium"
        }
        launchGame(gamePk: session.gamePk, venueName: venueName, venueId: session.venueId)
    }

    // MARK: - Schedule → Game Selection (§6.2)

    private func selectGame(from games: [ScheduleResponse.ScheduleGame], venue: CachedVenue) async {
        if games.isEmpty {
            noGameVenue = venue
            await fetchNextHomeGame(for: venue)
            state = .entry
            return
        }

        let gamePk: Int
        if games.count == 1 {
            gamePk = games[0].gamePk
        } else {
            // Doubleheader. Status comes from abstractGameState, so a delayed
            // game still counts as under way and a postponed one counts as over.
            let inProgress = games.filter { $0.status.isUnderway }
            if inProgress.count == 1 {
                gamePk = inProgress[0].gamePk
            } else if inProgress.isEmpty {
                let notFinal = games.first { !$0.status.isOver }
                gamePk = (notFinal ?? games[0]).gamePk
            } else {
                gamePk = games[0].gamePk
            }
        }

        launchGame(gamePk: gamePk, venueName: venue.name, venueId: venue.id)
    }

    // MARK: - Next Home Game

    private func fetchNextHomeGame(for venue: CachedVenue) async {
        // Use a schedule range search for the venue
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        // POSIX locale: API dates must not depend on the device's calendar setting
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let start = formatter.string(from: Date())
        let end: String = {
            let future = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
            return formatter.string(from: future)
        }()
        let urlString = "https://statsapi.mlb.com/api/v1/schedule?sportId=1,11,12,13,14&venueIds=\(venue.id)&startDate=\(start)&endDate=\(end)&hydrate=team&gameTypes=R,F,D,L,W"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ScheduleResponse.self, from: data)
            let future = resp.validGames.filter { !$0.status.isOver }
            if let first = future.first {
                nextHomeGame = mapToSummary(first)
            }
        } catch {}
    }

    // MARK: - Helpers

    private func mapToSummary(_ game: ScheduleResponse.ScheduleGame) -> GameSummary? {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        guard let gameDate = dateFormatter.date(from: game.gameDate) else { return nil }

        let sportId = game.teams.home.team.sport?.id ?? 1

        return GameSummary(
            id: game.gamePk,
            gamePk: game.gamePk,
            homeTeam: game.teams.home.team.name,
            awayTeam: game.teams.away.team.name,
            homeAbbr: game.teams.home.team.abbreviation ?? String(game.teams.home.team.name.prefix(3)).uppercased(),
            awayAbbr: game.teams.away.team.abbreviation ?? String(game.teams.away.team.name.prefix(3)).uppercased(),
            homeScore: game.teams.home.score,
            awayScore: game.teams.away.score,
            detailedState: game.status.detailedState,
            gameDate: gameDate,
            venueId: game.venue.id,
            venueName: game.venue.name ?? "Stadium",
            sportId: sportId,
            currentInning: game.linescore?.currentInning,
            inningState: game.linescore?.inningState,
            isUnderway: game.status.isUnderway,
            isOver: game.status.isOver,
            startTimeTBD: game.status.startTimeTBD == true
        )
    }

    private func todayDateString() -> String {
        // Baseball day rolls over at 3am ET so late West Coast games
        // remain visible after local midnight.
        let etZone = TimeZone(identifier: "America/New_York") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = etZone
        let hourET = cal.component(.hour, from: Date())
        let base = hourET < 3
            ? cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            : Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = etZone
        // POSIX locale: API dates must not depend on the device's calendar setting
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: base)
    }

    // MARK: - Session Persistence

    private func saveSession(_ session: ActiveSession) {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    private func loadSession() -> ActiveSession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(ActiveSession.self, from: data)
        else { return nil }
        return session
    }

    private func clearSession() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    // MARK: - App Lifecycle

    func handleForeground() {
        gameVM?.handleForeground()
    }

    func handleBackground() {
        gameVM?.stopPolling()
    }
}
