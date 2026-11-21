import Foundation

/// What Tempus is asked with for a sample: the instant and the height.
/// Mirrors `tabularius/internal/conditions/instant.go` and the height
/// rule of the backend (`hooks.SampleElevation`) — the app queries
/// Tempus itself when it is online, so both sides must ask the same.
public enum ConditionsQuery {
    /// Heights Tempus accepts, metres above sea level.
    public static let elevationRange: ClosedRange<Double> = -500 ... 9000

    /// How old the queried instant must be before Tempus answers from
    /// the final archive instead of forecast data.
    public static let finalAfter: TimeInterval = 120 * 3600

    /// Local hours queried for a sample without a time of day.
    private static let allDayHour = 14
    private static let allDayNightHour = 22

    /// The instant (whole seconds) Tempus is asked for:
    ///
    /// - a sample with a time of day: its begin
    /// - an all-day sample: 14:00 on the local calendar day of `begin`
    ///   in `timezone`
    /// - an all-day sample of a night fieldtrip: 22:00 on that day
    ///
    /// An unknown or empty zone counts as UTC.
    public static func instant(begin: Date, timezone: String, isAllDay: Bool, night: Bool) -> Date {
        guard isAllDay else {
            return Date(timeIntervalSince1970: begin.timeIntervalSince1970.rounded(.down))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
        var parts = calendar.dateComponents([.year, .month, .day], from: begin)
        parts.hour = night ? allDayNightHour : allDayHour
        return calendar.date(from: parts) ?? begin
    }

    /// Same instant to the second (stored dates lose sub-second
    /// precision). A missing date never matches.
    public static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return a.timeIntervalSince1970.rounded(.down) == b.timeIntervalSince1970.rounded(.down)
    }

    /// Whether `instant` was at least `finalAfter` in the past when the
    /// answer was fetched.
    public static func isFinalAge(instant: Date, fetchedAt: Date) -> Bool {
        fetchedAt.timeIntervalSince(instant) >= finalAfter
    }

    /// The height in whole metres (the resolution Tempus tells apart),
    /// or nil when the sample cannot be asked: no height source (a
    /// stored 0 is no height then) or a height outside the range.
    public static func elevationMetres(_ elevation: Double?, hasSource: Bool) -> Int? {
        guard hasSource, let elevation, elevationRange.contains(elevation) else { return nil }
        return Int(elevation.rounded())
    }
}
