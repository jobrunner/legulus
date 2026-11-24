@testable import Legulus
import XCTest

/// The 24-hour light band of the „Zeit“ card: night, twilights and day
/// as segments, the sample's window and the moon on top.
final class LightBandTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    /// „HH:mm“ on 23.11.2026 in Berlin (UTC+1).
    private func t(_ hhmm: String, day: Int = 23) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents(year: 2026, month: 11, day: day, hour: parts[0], minute: parts[1])
        c.timeZone = zone
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    /// Würzburg, 23.11.2026.
    private var events: SkyEvents {
        SkyEvents(
            astronomicalDawn: t("05:55"), nauticalDawn: t("06:30"), civilDawn: t("07:05"), sunrise: t("07:43"),
            sunset: t("16:29"), civilDusk: t("17:07"), nauticalDusk: t("17:48"), astronomicalDusk: t("18:27"),
            moonrise: t("13:20"), moonset: t("02:50")
        )
    }

    private func phases(_ band: LightBand) -> [LightBand.Phase] {
        band.segments.map(\.phase)
    }

    func testDayBand_RunsFromMidnightToMidnight() {
        let band = LightBand(begin: t("11:15"), end: t("11:45"), isAllDay: false, events: events,
                             zone: zone, nightCentered: false)
        XCTAssertEqual(band.start, t("00:00"))
        XCTAssertEqual(phases(band), [.night, .astronomical, .nautical, .civil, .day,
                                      .civil, .nautical, .astronomical, .night])
        let day = band.segments[4]
        XCTAssertEqual(day.from, 7.0 / 24 + 43.0 / 1440, accuracy: 1e-6, "sunrise 07:43")
        XCTAssertEqual(day.to, 16.0 / 24 + 29.0 / 1440, accuracy: 1e-6, "sunset 16:29")
        XCTAssertEqual(band.begin ?? -1, 11.25 / 24, accuracy: 1e-6)
        XCTAssertEqual(band.window?.lowerBound ?? -1, 11.25 / 24, accuracy: 1e-6)
        XCTAssertEqual(band.window?.upperBound ?? -1, 11.75 / 24, accuracy: 1e-6)
    }

    /// A night sample puts the night in the middle: 12:00 to 12:00.
    func testNightBand_RunsFromNoonToNoon() {
        let band = LightBand(begin: t("21:40"), end: t("03:10", day: 24), isAllDay: false, events: events,
                             zone: zone, nightCentered: true)
        XCTAssertEqual(band.start, t("12:00"))
        XCTAssertEqual(phases(band), [.day, .civil, .nautical, .astronomical, .night,
                                      .astronomical, .nautical, .civil, .day])
        XCTAssertEqual(band.window?.lowerBound ?? -1, 9.0 / 24 + 40.0 / 1440, accuracy: 1e-6)
        XCTAssertEqual(band.window?.upperBound ?? -1, 15.0 / 24 + 10.0 / 1440, accuracy: 1e-6)
    }

    /// After midnight a night band starts the day before at noon.
    func testNightBand_AfterMidnightStartsTheNoonBefore() {
        let band = LightBand(begin: t("01:30", day: 24), end: nil, isAllDay: false, events: events,
                             zone: zone, nightCentered: true)
        XCTAssertEqual(band.start, t("12:00"))
        XCTAssertNil(band.window, "no end, no window")
    }

    /// The moon is up from 13:20 to 02:50 the next morning.
    func testMoonUp_SpansMidnight() {
        let band = LightBand(begin: t("21:40"), end: nil, isAllDay: false, events: events,
                             zone: zone, nightCentered: true)
        XCTAssertEqual(band.moonUp.count, 1)
        XCTAssertEqual(band.moonUp.first?.lowerBound ?? -1, 80.0 / 1440, accuracy: 1e-6, "13:20")
        XCTAssertEqual(band.moonUp.first?.upperBound ?? -1, 14.0 / 24 + 50.0 / 1440, accuracy: 1e-6, "02:50")
    }

    /// High summer far north: no astronomical times, the sun stays above
    /// -18°: no night, the darkest part is astronomical twilight.
    func testNoAstronomicalTimes_MeansNoNight() {
        var e = events
        e.astronomicalDawn = nil
        e.astronomicalDusk = nil
        let band = LightBand(begin: t("11:15"), end: nil, isAllDay: false, events: e, zone: zone, nightCentered: false)
        XCTAssertFalse(phases(band).contains(.night))
        XCTAssertEqual(phases(band).first, .astronomical)
    }

    /// Without any times there is nothing to draw.
    func testNoTimes_IsEmpty() {
        let band = LightBand(begin: t("11:15"), end: nil, isAllDay: false, events: SkyEvents(),
                             zone: zone, nightCentered: false)
        XCTAssertTrue(band.segments.isEmpty)
    }

    func testAllDay_HasNoWindowAndNoBegin() {
        let band = LightBand(begin: t("14:00"), end: nil, isAllDay: true, events: events, zone: zone, nightCentered: false)
        XCTAssertNil(band.window)
        XCTAssertNil(band.begin)
    }

    func testCompass_SixteenPoints() {
        XCTAssertEqual(LightBand.compass(0), "N")
        XCTAssertEqual(LightBand.compass(135), "SO")
        XCTAssertEqual(LightBand.compass(170), "S")
        XCTAssertEqual(LightBand.compass(292), "WNW")
        XCTAssertEqual(LightBand.compass(359), "N")
    }
}
