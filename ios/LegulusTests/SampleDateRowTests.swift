@testable import Legulus
import XCTest

/// Date and time window of the sample view: format by the device's
/// region, weekday and month short; one day or a range over several
/// days, with or without a time of day.
@MainActor
final class SampleDateRowTests: XCTestCase {
    private let german = Locale(identifier: "de_DE")
    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    /// The locale uses narrow and thin no-break spaces (before „PM“,
    /// around the range dash); compared as plain spaces.
    private func plain(_ text: String?) -> String? {
        text.map { $0.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ") }
    }

    private func texts(
        _ begin: String, _ end: String?, allDay: Bool = false, zone: TimeZone? = nil, locale: Locale? = nil
    ) throws -> SampleDateTexts {
        try SampleDateTexts(
            begin: date(begin), end: end.map { try date($0) }, isAllDay: allDay,
            zone: zone ?? berlin, locale: locale ?? german
        )
    }

    /// One day with a time window: short weekday and month.
    func testOneDayWithTime() throws {
        let t = try texts("2026-11-23T15:45:00Z", "2026-11-23T16:00:00Z")
        XCTAssertEqual(plain(t.date), "Mo. 23. Nov. 2026")
        XCTAssertEqual(plain(t.weekday), "Mo.", "for the break after the weekday at large type")
        XCTAssertEqual(plain(t.dayAndYear), "23. Nov. 2026")
        XCTAssertEqual(plain(t.window), "16:45 – 17:00")
        XCTAssertEqual(plain(t.spoken), "Montag, 23. November 2026, 16:45 – 17:00")
    }

    func testOneInstantWithoutEnd() throws {
        let t = try texts("2026-11-23T15:45:00Z", nil)
        XCTAssertEqual(plain(t.window), "16:45")
    }

    /// Over midnight: the date is a range, the window only times.
    func testOverNightWithTime() throws {
        let t = try texts("2026-11-23T20:40:00Z", "2026-11-24T02:10:00Z")
        XCTAssertEqual(plain(t.date), "Mo. 23. – Di. 24. Nov. 2026")
        XCTAssertNil(t.weekday, "a range wraps as a whole")
        XCTAssertEqual(plain(t.window), "21:40 – 03:10")
    }

    func testOneDayAllDay() throws {
        let t = try texts("2026-11-23T11:00:00Z", nil, allDay: true)
        XCTAssertEqual(plain(t.date), "Mo. 23. Nov. 2026")
        XCTAssertNil(t.window, "all-day: the date alone")
    }

    func testSeveralDaysAllDay() throws {
        let t = try texts("2026-11-23T11:00:00Z", "2026-11-25T11:00:00Z", allDay: true)
        XCTAssertEqual(plain(t.date), "Mo. 23. – Mi. 25. Nov. 2026")
        XCTAssertNil(t.window)
        XCTAssertEqual(plain(t.spoken), "Montag, 23. – Mittwoch, 25. November 2026")
    }

    /// The device's region decides order, punctuation and the clock.
    func testFollowsTheLocale() throws {
        let t = try texts("2026-11-23T15:45:00Z", "2026-11-23T16:00:00Z", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(plain(t.date), "Mon, Nov 23, 2026")
        XCTAssertEqual(plain(t.window), "4:45 PM – 5:00 PM")
    }

    /// 23:30 UTC ist in Auckland schon der nächste Tag.
    func testUsesTheLocalDayOfTheZone() throws {
        let t = try texts("2026-11-16T23:30:00Z", nil, zone: TimeZone(identifier: "Pacific/Auckland"))
        XCTAssertEqual(plain(t.date), "Di. 17. Nov. 2026")
    }
}
