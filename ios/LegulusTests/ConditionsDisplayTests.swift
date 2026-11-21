@testable import Legulus
import LegulusGeo
import XCTest

final class ConditionsDisplayTests: XCTestCase {
    private var store: LocalSampleStore!
    /// 2026-05-19 12:00 UTC.
    private let begin = Date(timeIntervalSince1970: 1_779_192_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try LocalSampleStore(
            database: Database(inMemory: ()), userId: "u1", timeZone: .gmt,
            settings: { SampleIDSettings(cutoffHour: 5) }
        )
    }

    private func sample(elevation: Double? = 250) throws -> LocalSample {
        var s = try store.createLocal(lat: 49.68, lon: 10.04, elevation: elevation, collectedFrom: begin)
        s.timezone = "Europe/Berlin"
        return s
    }

    /// The sample with the answer of `TempusFixtures.allOk` (0 °C, 85 %,
    /// 7,4 km/h, code 61, sun, moon), as the resolver stores it.
    private func answered(
        _ sample: LocalSample, fetchedAfter: TimeInterval = 40 * 86400, json: String = TempusFixtures.allOk
    ) throws -> (LocalSample, [LocalSampleFeature]) {
        var s = sample
        let request = try XCTUnwrap(ConditionsRequest(s, night: false))
        let result = ConditionsMapper.map(
            TempusFixtures.response(json), queriedFor: request.instant,
            fetchedAt: request.instant.addingTimeInterval(fetchedAfter)
        )
        var conditions = SampleConditions(result)
        conditions.inputs = request.inputs
        conditions.featuresFetchedAt = result.fetchedAt
        s.conditions = conditions
        let rows = result.features.map { LocalSampleFeature(sampleID: s.id, feature: $0, fetchedAt: result.fetchedAt) }
        return (s, rows)
    }

    // MARK: - states

    func testState_NoCoordinate() throws {
        var s = try sample()
        s.latitude = nil
        s.longitude = nil
        XCTAssertEqual(ConditionsDisplay(sample: s, night: false, features: []).state, .noCoordinate)
    }

    func testState_WaitingForElevation() throws {
        let s = try sample(elevation: nil)
        XCTAssertEqual(ConditionsDisplay(sample: s, night: false, features: []).state, .waitingForElevation)
    }

    /// Not on the server yet, or the server is asking: being determined.
    func testState_Pending() throws {
        var s = try sample()
        XCTAssertEqual(ConditionsDisplay(sample: s, night: false, features: []).state, .pending)
        s.backendId = "backend-1"
        s.syncStatus = .synced
        s.conditions = .pending
        XCTAssertEqual(ConditionsDisplay(sample: s, night: false, features: []).state, .pending)
    }

    /// Synced and never processed by the server: a sample from before.
    func testState_Legacy() throws {
        var s = try sample()
        s.backendId = "backend-1"
        s.syncStatus = .synced
        XCTAssertEqual(ConditionsDisplay(sample: s, night: false, features: []).state, .legacy)
    }

    /// Values that no longer fit the sample are not shown.
    func testState_StaleValuesCountAsPending() throws {
        var (s, rows) = try answered(sample())
        s.elevation = 800
        let display = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(display.state, .pending)
        XCTAssertTrue(display.isEmpty)
    }

    // MARK: - values

    func testValues_FormatsAndZero() throws {
        let (s, rows) = try answered(sample())
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(d.state, .values)
        XCTAssertFalse(d.isProvisional)
        XCTAssertEqual(d.temperature, "0,0\u{00A0}°C", "0 °C is a value and is shown")
        XCTAssertEqual(d.temperatureSpoken, "0,0 Grad Celsius")
        XCTAssertEqual(d.weatherSymbol, "cloud.rain")
        XCTAssertEqual(d.weatherTitle, "Regen", "fallback text: the trimmed fixture has no description")
        XCTAssertEqual(d.hourly.map(\.label), ["Luftfeuchte", "Wind"], "what Tempus did not deliver is not listed")
        XCTAssertEqual(d.hourly.map(\.value), ["85\u{00A0}%", "7\u{00A0}km/h"])
        XCTAssertEqual(d.hourly.first?.spoken, "Luftfeuchte 85 Prozent")
        XCTAssertNil(d.note)
    }

    func testValues_SunTimesInTheSamplesZone() throws {
        var base = try sample()
        base.timezone = "Atlantic/Canary"
        let (s, rows) = try answered(base)
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        // 03:27Z and 19:02Z; the Canaries are at UTC+1 in May.
        XCTAssertEqual(d.sky.map(\.value), ["Neumond, 5\u{00A0}%", "04:27", "20:02"])
        XCTAssertEqual(d.sky.last?.spoken, "Sonnenuntergang 20:02 Uhr")
    }

    func testValues_Provisional() throws {
        let (s, rows) = try answered(sample(), fetchedAfter: 3600)
        XCTAssertTrue(ConditionsDisplay(sample: s, night: false, features: rows).isProvisional)
    }

    /// An all-day sample shows day values only.
    func testValues_AllDayHidesHourlyWeather() throws {
        var base = try sample()
        base.isAllDay = true
        let (s, rows) = try answered(base)
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(d.state, .values)
        XCTAssertNil(d.temperature)
        XCTAssertNil(d.weatherSymbol)
        XCTAssertTrue(d.hourly.isEmpty)
        XCTAssertEqual(d.sky.count, 3)
        XCTAssertNil(d.note)
        XCTAssertEqual(d.attribution, "NOAA · Meeus", "the weather source is not shown without weather values")
    }

    /// A final answer without weather for a sample with a time of day.
    func testValues_FinalWithoutWeatherSaysSo() throws {
        let noWeather = """
        {"features": [{"properties": {"kind": "moon", "phase": {"de": "Neumond"}, "illuminationPct": 4.5},
                       "license": {"name": "PD", "attribution": "Meeus"}}],
         "providers": [{"id": "open-meteo", "kind": "weather", "status": "error"},
                       {"id": "moon", "kind": "moon", "status": "ok"}]}
        """
        let (s, rows) = try answered(sample(), json: noWeather)
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(d.note, "Keine Daten für diesen Zeitpunkt")
        XCTAssertEqual(d.sky.map(\.label), ["Mond"], "what is there is still shown")
    }

    func testValues_DailyClimateAndAttribution() throws {
        let rich = """
        {"features": [
          {"properties": {"kind": "weather", "temperature2m": 16, "weatherCode": 61,
                          "weatherCodeDescription": {"de": "Leichter Regen"}},
           "license": {"name": "CC-BY 4.0", "attribution": "Quelle A"}},
          {"properties": {"kind": "dewpoint", "dewPoint2m": 13.5},
           "license": {"name": "CC-BY 4.0", "attribution": "Quelle A"}},
          {"properties": {"kind": "aggregate", "precipitation": {"last24h": 34, "last72h": 62.5, "last120h": 62.7},
                          "temperatureDay": {"min": 14.2, "max": 18.5, "mean": 17.3}},
           "license": {"name": "CC-BY 4.0", "attribution": "Quelle B"}},
          {"properties": {"kind": "bioclim", "koppen": {"code": "Dfb"},
                          "altitudinalBelt": {"belt": {"de": "submontan-kollin"}}},
           "license": {"name": "CC-BY 4.0", "attribution": "Quelle B"}}
        ], "providers": []}
        """
        let (s, rows) = try answered(sample(), json: rich)
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(d.weatherTitle, "Leichter Regen", "the text comes from the feature")
        XCTAssertEqual(d.temperature, "16,0\u{00A0}°C")
        XCTAssertEqual(d.hourly.map(\.value), ["13,5\u{00A0}°C"])
        XCTAssertEqual(
            d.daily.map(\.label),
            ["Niederschlag 24\u{00A0}h", "Niederschlag 72\u{00A0}h", "Niederschlag 120\u{00A0}h", "Tag", "Tagesmittel"]
        )
        XCTAssertEqual(
            d.daily.map(\.value),
            ["34,0\u{00A0}mm", "62,5\u{00A0}mm", "62,7\u{00A0}mm", "14,2 – 18,5\u{00A0}°C", "17,3\u{00A0}°C"]
        )
        XCTAssertEqual(d.daily[3].spoken, "Tagestemperatur 14,2 bis 18,5 Grad Celsius")
        XCTAssertEqual(d.climate?.value, "Dfb · submontan-kollin")
        XCTAssertEqual(d.climate?.spoken, "Köppen-Klima Dfb, Höhenstufe submontan-kollin")
        XCTAssertEqual(d.attribution, "Quelle A · Quelle B", "each source once")
    }

    /// After a pull the row holds the server's new answer while the
    /// stored features still belong to the previous one (they are
    /// fetched afterwards, and that can fail). Their text and sources
    /// must not appear next to the new values.
    func testValues_FeaturesOfAnotherAnswerAreNotUsed() throws {
        let rich = """
        {"features": [{"properties": {"kind": "weather", "temperature2m": 16, "weatherCode": 61,
                                      "weatherCodeDescription": {"de": "Leichter Regen"}},
                       "license": {"name": "CC-BY 4.0", "attribution": "Quelle A"}}], "providers": []}
        """
        var (s, rows) = try answered(sample(), json: rich)
        XCTAssertEqual(ConditionsDisplay(sample: s, night: false, features: rows).weatherTitle, "Leichter Regen")

        // A newer answer arrived; the rows are still the old ones.
        let newer = s.conditions?.fetchedAt?.addingTimeInterval(86400)
        s.conditions?.fetchedAt = newer
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(d.weatherTitle, "Regen", "the text of the code, not the old feature's")
        XCTAssertNil(d.attribution)
        XCTAssertEqual(d.temperature, "16,0\u{00A0}°C", "the values themselves are the row's and stay")
        XCTAssertTrue(ConditionsDetailModel(sample: s, night: false, features: rows).isEmpty)
    }

    func testNumber_GermanDecimalsAndNoNegativeZero() {
        XCTAssertEqual(ConditionsDisplay.number(18.44, digits: 1), "18,4")
        XCTAssertEqual(ConditionsDisplay.number(-0.04, digits: 1), "0,0")
        XCTAssertEqual(ConditionsDisplay.number(-3.75, digits: 1), "-3,8")
        XCTAssertEqual(ConditionsDisplay.number(1234.5, digits: 0), "1235")
    }
}
