@testable import Legulus
import XCTest

/// What the „Zeit“ card shows of the sky: the light band, sunrise and
/// sunset under it, the lines about sun and moon.
final class TimeCardSkyTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    private let german = Locale(identifier: "de_DE")

    private func t(_ hhmm: String, day: Int = 23) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents(year: 2026, month: 11, day: day, hour: parts[0], minute: parts[1])
        c.timeZone = zone
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    private func display(phase: ConditionsDisplay.LightPhase) -> ConditionsDisplay {
        var d = ConditionsDisplay(state: .values)
        d.lightPhase = phase
        d.skyEvents = SkyEvents(
            astronomicalDawn: t("05:55"), nauticalDawn: t("06:30"), civilDawn: t("07:05"), sunrise: t("07:43"),
            sunset: t("16:29"), civilDusk: t("17:07"), nauticalDusk: t("17:48"), astronomicalDusk: t("18:27"),
            moonrise: t("13:20"), moonset: t("02:50")
        )
        d.sunFact = "Sonne 18° hoch, S"
        d.moonFact = "Mond unter dem Horizont · Aufgang 13:20"
        d.sunIsUp = true
        return d
    }

    func testDay_BandFromMidnightWithSunTimesAndFacts() throws {
        let sky = try XCTUnwrap(TimeCardSky(display: display(phase: .day), begin: t("11:15"), end: t("11:45"),
                                            isAllDay: false, zone: zone, locale: german))
        XCTAssertFalse(sky.band.nightCentered)
        XCTAssertEqual(sky.sunrise?.text, "↑ 07:43")
        XCTAssertEqual(sky.sunset?.text, "↓ 16:29")
        XCTAssertEqual(sky.facts, ["Sonne 18° hoch, S"], "by day the moon is left out")
        XCTAssertTrue(sky.markers.sunIsUp)
        XCTAssertFalse(sky.markers.showsMoon)
        XCTAssertEqual(sky.accessibilityText, "Probe am Tag, Sonnenaufgang 07:43, Sonnenuntergang 16:29")
    }

    /// At night the band runs noon to noon and the sunset comes first.
    func testNight_BandFromNoon() throws {
        let sky = try XCTUnwrap(TimeCardSky(display: display(phase: .night), begin: t("21:40"),
                                            end: t("03:10", day: 24), isAllDay: false, zone: zone, locale: german))
        XCTAssertTrue(sky.band.nightCentered)
        XCTAssertLessThan(sky.sunset?.at ?? 1, sky.sunrise?.at ?? 0)
        XCTAssertEqual(sky.accessibilityText, "Probe in der Nacht, Sonnenaufgang 07:43, Sonnenuntergang 16:29")
        XCTAssertEqual(sky.facts, ["Mond unter dem Horizont · Aufgang 13:20"], "at night the sun is left out")
        XCTAssertFalse(sky.markers.sunIsUp)
        XCTAssertTrue(sky.markers.showsMoon)
    }

    /// Twilight shows both.
    func testTwilight_SunAndMoon() throws {
        let sky = try XCTUnwrap(TimeCardSky(display: display(phase: .twilight), begin: t("16:50"), end: t("17:20"),
                                            isAllDay: false, zone: zone, locale: german))
        XCTAssertEqual(sky.facts, ["Sonne 18° hoch, S", "Mond unter dem Horizont · Aufgang 13:20"])
        XCTAssertTrue(sky.markers.showsMoon)
    }

    /// Without values or without sun times there is no band.
    /// Polar day or night: no sun times, so no band, but the lines about
    /// sun and moon stay.
    func testNoSunTimes_KeepsFactsWithoutBand() throws {
        var polar = ConditionsDisplay(state: .values)
        polar.lightPhase = .day
        polar.sunFact = "Sonne 5° hoch, S"
        let sky = try XCTUnwrap(TimeCardSky(display: polar, begin: t("11:15"), end: nil, isAllDay: false,
                                            zone: zone, locale: german))
        XCTAssertFalse(sky.showsBand)
        XCTAssertEqual(sky.facts, ["Sonne 5° hoch, S"])
    }

    func testNoValues_NoSky() {
        XCTAssertNil(TimeCardSky(display: ConditionsDisplay(state: .pending), begin: t("11:15"), end: nil,
                                 isAllDay: false, zone: zone, locale: german))
        var empty = ConditionsDisplay(state: .values)
        empty.lightPhase = .day
        XCTAssertNil(TimeCardSky(display: empty, begin: t("11:15"), end: nil, isAllDay: false, zone: zone, locale: german))
    }
}
