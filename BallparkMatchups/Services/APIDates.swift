import Foundation

/// Dates in the formats the Stats API uses, with each formatter built once.
enum APIDates {
    private static let eastern = TimeZone(identifier: "America/New_York") ?? .current

    /// yyyy-MM-dd in Eastern time, for schedule requests.
    private static let easternDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = eastern
        // POSIX locale: API dates must not depend on the device's calendar setting
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// yyyy-MM-dd in the device's time zone, for dates such as a birth date.
    private static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // ISO8601DateFormatter is documented thread-safe but not marked Sendable.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The baseball day, as yyyy-MM-dd. It rolls over at 3 a.m. Eastern for
    /// every venue, so late West Coast games stay listed after local midnight.
    static func todayString(offsetDays: Int = 0) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        let now = Date()
        let rollback = cal.component(.hour, from: now) < 3 ? -1 : 0
        let day = cal.date(byAdding: .day, value: rollback + offsetDays, to: now) ?? now
        return easternDay.string(from: day)
    }

    /// An ISO 8601 timestamp, with or without fractional seconds.
    static func parseISO(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? iso.date(from: string)
    }

    /// A yyyy-MM-dd date, read in the device's time zone.
    static func parseDay(_ string: String) -> Date? {
        localDay.date(from: string)
    }
}
