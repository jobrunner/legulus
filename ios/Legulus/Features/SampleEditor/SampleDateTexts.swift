import Foundation

/// Date and time window of a sample for the sample view, in the sample's
/// zone and the device's region: the formatter gets the fields (short
/// weekday, day, short month, year; hour and minute), the locale decides
/// order, punctuation and the 12/24-hour clock.
///
/// - one day with times: „Mo., 23. Nov. 2026“ and „16:45 – 17:00“
/// - over midnight: „Mo., 23. – Di., 24. Nov. 2026“ and „21:40 – 03:10“
/// - all-day: the date or date range alone
struct SampleDateTexts: Equatable {
    /// The day, or the range of days.
    let date: String
    /// Weekday and the rest of a single day, for the break after the
    /// weekday at large type sizes; nil for a range, which wraps as a whole.
    let weekday: String?
    let dayAndYear: String?
    /// Begin and end times; nil for an all-day sample.
    let window: String?
    /// For VoiceOver: weekday and month written out, a short weekday
    /// would be read as a syllable.
    let spoken: String

    init(begin: Date, end: Date?, isAllDay: Bool, zone: TimeZone, locale: Locale = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = locale
        let last = end.flatMap { $0 > begin ? $0 : nil }
        let rangeEnd = last.flatMap { calendar.isDate($0, inSameDayAs: begin) ? nil : $0 }

        if let rangeEnd {
            date = Self.interval(begin, rangeEnd, template: "EEEdMMMyyyy", zone: zone, locale: locale, calendar: calendar)
            weekday = nil
            dayAndYear = nil
        } else {
            date = Self.format(begin, template: "EEEdMMMyyyy", zone: zone, locale: locale)
            // The weekday as it stands in the date („Mo.“), not the
            // stand-alone form a template alone gives („Mo“).
            weekday = Self.weekdayInDate(begin, zone: zone, locale: locale)
            dayAndYear = Self.format(begin, template: "dMMMyyyy", zone: zone, locale: locale)
        }

        if isAllDay {
            window = nil
        } else {
            let from = Self.format(begin, template: "jmm", zone: zone, locale: locale)
            window = last.map { "\(from) – \(Self.format($0, template: "jmm", zone: zone, locale: locale))" } ?? from
        }

        let spokenDate = rangeEnd.map {
            Self.interval(begin, $0, template: "EEEEdMMMMyyyy", zone: zone, locale: locale, calendar: calendar)
        } ?? Self.format(begin, template: "EEEEdMMMMyyyy", zone: zone, locale: locale)
        spoken = [spokenDate, window].compactMap { $0 }.joined(separator: ", ")
    }

    private static func format(_ date: Date, template: String, zone: TimeZone, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    private static func weekdayInDate(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private static func interval(
        _ from: Date, _ to: Date, template: String, zone: TimeZone, locale: Locale, calendar: Calendar
    ) -> String {
        let f = DateIntervalFormatter()
        f.locale = locale
        f.timeZone = zone
        f.calendar = calendar
        f.dateTemplate = template
        return f.string(from: from, to: to)
    }
}
