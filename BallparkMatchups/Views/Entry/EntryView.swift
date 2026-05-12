import SwiftUI

struct EntryView: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                    .padding(.top, 60)
                    .padding(.horizontal, 24)

                if !app.disambiguationVenues.isEmpty {
                    disambiguationSection
                        .padding(.top, 32)
                        .padding(.horizontal, 24)
                }

                if let venue = app.noGameVenue {
                    noGameSection(venue: venue)
                        .padding(.top, 32)
                        .padding(.horizontal, 24)
                }

                actionButtons
                    .padding(.top, 48)
                    .padding(.horizontal, 24)

                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BALLPARK\nMATCHUPS")
                .font(.system(size: 34, weight: .black, design: .default))
                .foregroundColor(Theme.primaryText)
                .lineSpacing(4)

            Text("Live batter vs. pitcher data.")
                .labelFont(size: 15)
        }
    }

    // MARK: - Disambiguation

    private var disambiguationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MULTIPLE VENUES NEARBY")
                .labelFont(size: 11)
                .kerning(1.5)

            ForEach(app.disambiguationVenues, id: \.id) { venue in
                Button {
                    Task { await app.resolveVenue(venue) }
                } label: {
                    HStack {
                        Text(venue.name)
                            .primaryFont(size: 17)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.secondaryText)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - No Game Today

    private func noGameSection(venue: CachedVenue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NO GAME TODAY AT \(venue.name.uppercased())")
                .primaryFont(size: 16, weight: .bold)

            if let next = app.nextHomeGame {
                let dateStr = formatDate(next.gameDate)
                Text("Next home game: \(dateStr)")
                    .labelFont(size: 14)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Buttons

    private var actionButtons: some View {
        VStack(spacing: 16) {
            Button {
                Task { await app.detectLocation() }
            } label: {
                HStack {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16))
                    Text("Detect where I am")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.primaryText)
                .foregroundColor(.black)
            }

            Button {
                app.state = .browseGames
                Task { await app.loadBrowseGames() }
            } label: {
                HStack {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16))
                    Text("Browse today's games")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.situationBackground)
                .foregroundColor(Theme.primaryText)
                .overlay(
                    Rectangle()
                        .stroke(Color(hex: "#333333"), lineWidth: 1)
                )
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d 'at' h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Location Denied

struct LocationDeniedView: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LOCATION ACCESS NEEDED")
                    .primaryFont(size: 20, weight: .bold)
                Text("BallparkMatchups needs your location to detect which game you're at.")
                    .labelFont(size: 15)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.primaryText)
                        .foregroundColor(.black)
                        .font(.system(size: 17, weight: .semibold))
                }

                Button {
                    app.state = .browseGames
                    Task { await app.loadBrowseGames() }
                } label: {
                    Text("Pick ballpark manually")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.situationBackground)
                        .foregroundColor(Theme.primaryText)
                        .font(.system(size: 17, weight: .semibold))
                        .overlay(Rectangle().stroke(Color(hex: "#333333"), lineWidth: 1))
                }
            }
        }
        .padding(24)
    }
}

// MARK: - Location Failed

struct LocationFailedView: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("COULDN'T DETECT LOCATION")
                    .primaryFont(size: 20, weight: .bold)
                Text("Try moving to an open area, or pick your ballpark manually.")
                    .labelFont(size: 15)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await app.detectLocation() }
                } label: {
                    Text("Try Again")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.primaryText)
                        .foregroundColor(.black)
                        .font(.system(size: 17, weight: .semibold))
                }

                Button {
                    app.state = .browseGames
                    Task { await app.loadBrowseGames() }
                } label: {
                    Text("Pick ballpark manually")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.situationBackground)
                        .foregroundColor(Theme.primaryText)
                        .font(.system(size: 17, weight: .semibold))
                        .overlay(Rectangle().stroke(Color(hex: "#333333"), lineWidth: 1))
                }
            }
        }
        .padding(24)
    }
}

// MARK: - Not At Ballpark

struct NotAtBallparkView: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NOT AT A BALLPARK")
                    .primaryFont(size: 20, weight: .bold)
                Text("You're not currently at an MLB or MiLB venue.\nOpen this app at the game for live matchup data.")
                    .labelFont(size: 15)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                app.state = .browseGames
                Task { await app.loadBrowseGames() }
            } label: {
                Text("Browse today's games")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.primaryText)
                    .foregroundColor(.black)
                    .font(.system(size: 17, weight: .semibold))
            }
        }
        .padding(24)
    }
}
