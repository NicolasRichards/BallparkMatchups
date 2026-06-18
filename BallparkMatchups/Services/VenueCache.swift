import Foundation
import CoreLocation

actor VenueCache {
    static let shared = VenueCache()

    private var venues: [CachedVenue] = []
    private var lastRefreshDate: Date?
    private let matchThresholdMeters: Double = 500

    private init() {}

    // MARK: - Load

    func load() async {
        if let cached = loadFromUserDefaults() {
            venues = cached.venues
            lastRefreshDate = cached.date
            return
        }
        loadFromBundle()
    }

    func reloadIfNeeded() async {
        let needsRefresh: Bool
        if let last = lastRefreshDate {
            let daysSince = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 999
            needsRefresh = daysSince > 30
        } else {
            needsRefresh = true
        }

        if needsRefresh {
            do {
                let response = try await MLBAPIClient.shared.fetchVenues()
                let mapped = response.venues.compactMap { detail -> CachedVenue? in
                    guard
                        let coords = detail.location?.defaultCoordinates,
                        let tzId = detail.timeZone?.id,
                        detail.active != false
                    else { return nil }
                    return CachedVenue(
                        id: detail.id,
                        name: detail.name,
                        teamName: nil,
                        latitude: coords.latitude,
                        longitude: coords.longitude,
                        timeZoneIdentifier: tzId,
                        sportId: 1  // can't determine from venue API alone; schedule will clarify
                    )
                }
                if !mapped.isEmpty {
                    venues = mapped
                    lastRefreshDate = Date()
                    saveToUserDefaults()
                }
            } catch {
                // Keep existing venues on failure
            }
        }
    }

    // MARK: - Matching

    func match(coordinate: CLLocationCoordinate2D) -> [CachedVenue] {
        venues.filter { venue in
            let venueLoc = CLLocation(latitude: venue.latitude, longitude: venue.longitude)
            let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return venueLoc.distance(from: userLoc) <= matchThresholdMeters
        }
    }

    func venue(id: Int) -> CachedVenue? {
        venues.first { $0.id == id }
    }

    // MARK: - Persistence

    private func loadFromBundle() {
        guard let url = Bundle.main.url(forResource: "venues", withExtension: "json") else { return }
        do {
            let data = try Data(contentsOf: url)
            let response = try JSONDecoder().decode(VenueListResponse.self, from: data)
            venues = response.venues.compactMap { detail -> CachedVenue? in
                guard
                    let coords = detail.location?.defaultCoordinates,
                    let tzId = detail.timeZone?.id
                else { return nil }
                return CachedVenue(
                    id: detail.id,
                    name: detail.name,
                    teamName: nil,
                    latitude: coords.latitude,
                    longitude: coords.longitude,
                    timeZoneIdentifier: tzId,
                    sportId: 1
                )
            }
        } catch {}
    }

    private struct PersistedCache: Codable {
        let venues: [CachedVenue]
        let date: Date
    }

    private let userDefaultsKey = "venueCache_v1"

    private func saveToUserDefaults() {
        let cache = PersistedCache(venues: venues, date: lastRefreshDate ?? Date())
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadFromUserDefaults() -> PersistedCache? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let cache = try? JSONDecoder().decode(PersistedCache.self, from: data)
        else { return nil }
        return cache
    }
}

// MARK: - Timezone Helper

extension CachedVenue {
    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    func todayDateString() -> String {
        // Roll over at 3am ET, not local midnight, so late games stay findable.
        let etZone = TimeZone(identifier: "America/New_York") ?? .current
        var etCal = Calendar(identifier: .gregorian)
        etCal.timeZone = etZone
        let hourET = etCal.component(.hour, from: Date())
        let base = hourET < 3
            ? etCal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            : Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = etZone
        // POSIX locale: API dates must not depend on the device's calendar setting
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: base)
    }
}
