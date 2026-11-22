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
        _ sample: LocalSample, fetchedAfter: TimeInterval = 40 * 86400, json: String = TempusFixtures.allOk,
        night: Bool = false
    ) throws -> (LocalSample, [LocalSampleFeature]) {
        var s = sample
        let request = try XCTUnwrap(ConditionsRequest(s, night: night))
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
        XCTAssertEqual(d.tiles.map(\.id), ["wind", "humidity"], "what Tempus did not deliver is not listed")
        XCTAssertEqual(d.tiles.map(\.value), ["7", "85"])
        XCTAssertEqual(d.tiles.map(\.unit), ["km/h", "%"])
        XCTAssertEqual(d.tiles.map(\.caption), ["Wind", "Feuchte"])
        XCTAssertEqual(d.tiles.map(\.word), ["leichte Brise", nil], "no dew point, no feeling")
        XCTAssertEqual(d.tiles.map(\.spoken), ["Wind leichte Brise, 7 Kilometer pro Stunde", "Luftfeuchte 85 Prozent"])
        XCTAssertNil(d.note)
    }

    func testValues_SunTimesInTheSamplesZone() throws {
        var base = try sample()
        base.timezone = "Atlantic/Canary"
        let (s, rows) = try answered(base)
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        // 03:27Z and 19:02Z; the Canaries are at UTC+1 in May.
        XCTAssertEqual(d.sunrise, "04:27")
        XCTAssertEqual(d.sunset, "20:02")
        XCTAssertEqual(d.moon?.value, "Neumond, 5\u{00A0}%")
        XCTAssertEqual(d.moonSymbol, "moonphase.new.moon")
    }

    /// 12:00 UTC lies between sunrise and sunset of the fixture; it has
    /// no twilight times, so day/night comes from sunrise and sunset.
    func testValues_DayShowsSunOnly() throws {
        let (s, rows) = try answered(sample())
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(d.lightPhase, .day)
        XCTAssertTrue(d.showsSun)
        XCTAssertFalse(d.showsMoon)
    }

    /// The twilight times come from the stored sun feature: 12:00 UTC
    /// lies between nautical and civil dawn here.
    func testValues_TwilightFromSunFeatureShowsBoth() throws {
        let json = """
        {"features": [{"properties": {"kind": "sun", "sunrise": "2026-05-19T13:00:00Z", "sunset": "2026-05-19T22:00:00Z",
                        "twilight": {"civil": {"dawn": "2026-05-19T12:30:00Z", "dusk": "2026-05-19T22:30:00Z"},
                                     "nautical": {"dawn": "2026-05-19T11:30:00Z", "dusk": "2026-05-19T23:00:00Z"}}},
                       "license": {"name": "PD", "attribution": "NOAA"}}], "providers": []}
        """
        let (s, rows) = try answered(sample(), json: json)
        let d = ConditionsDisplay(sample: s, night: false, features: rows)
        XCTAssertEqual(d.lightPhase, .twilight)
        XCTAssertTrue(d.showsSun)
        XCTAssertTrue(d.showsMoon)
    }

    /// The sun's elevation at the instant decides, whatever day the
    /// event times belong to (Tempus computes those for the UTC day).
    func testValues_ElevationDecidesOverEventTimes() throws {
        func display(elevation: Double) throws -> ConditionsDisplay {
            // Event times of another day: by them 12:00 UTC would be day.
            let json = """
            {"features": [{"properties": {"kind": "sun", "elevationDeg": \(elevation),
                            "sunrise": "2026-05-19T03:27:00Z", "sunset": "2026-05-19T19:02:00Z",
                            "twilight": {"civil": {"dawn": "2026-05-19T02:50:00Z", "dusk": "2026-05-19T19:40:00Z"},
                                         "nautical": {"dawn": "2026-05-19T02:00:00Z", "dusk": "2026-05-19T20:30:00Z"}}},
                           "license": {"name": "PD", "attribution": "NOAA"}}], "providers": []}
            """
            let (s, rows) = try answered(sample(), json: json)
            return ConditionsDisplay(sample: s, night: false, features: rows)
        }
        XCTAssertEqual(try display(elevation: -5.9).lightPhase, .day, "above -6°")
        XCTAssertEqual(try display(elevation: -6).lightPhase, .twilight)
        XCTAssertEqual(try display(elevation: -11.9).lightPhase, .twilight)
        XCTAssertEqual(try display(elevation: -12).lightPhase, .night)
    }

    /// An all-day sample has no instant of its own: night for a night
    /// fieldtrip, day otherwise.
    func testValues_AllDayLightPhaseFollowsFieldtrip() throws {
        var base = try sample()
        base.isAllDay = true
        let (day, dayRows) = try answered(base)
        XCTAssertEqual(ConditionsDisplay(sample: day, night: false, features: dayRows).lightPhase, .day)
        // A night fieldtrip asks for another instant.
        let (night, nightRows) = try answered(base, night: true)
        XCTAssertEqual(ConditionsDisplay(sample: night, night: true, features: nightRows).lightPhase, .night)
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
        XCTAssertTrue(d.tiles.isEmpty, "no hourly values, no day values in the fixture")
        XCTAssertNotNil(d.moon)
        XCTAssertNotNil(d.sunrise)
        XCTAssertEqual(d.note, "Keine Wetterdaten für diesen Tag", "the answer holds no day values")
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
        XCTAssertEqual(d.moon?.value, "Neumond, 5\u{00A0}%", "what is there is still shown")
    }

    func testValues_TilesAndClimate() throws {
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
        // Dew point without a percentage: the feeling alone. Only the
        // 72 h precipitation, no day temperatures; the belt moves to
        // the place.
        XCTAssertEqual(d.tiles.map(\.id), ["humidity", "precipitation72"])
        XCTAssertEqual(d.tiles.map(\.value), ["leicht feucht", "62,5"], "without a percentage the feeling is the value")
        XCTAssertEqual(d.tiles.map(\.unit), [nil, "mm"])
        XCTAssertEqual(d.tiles.map(\.caption), ["Feuchte", "72\u{00A0}h"])
        XCTAssertEqual(d.tiles.map(\.spoken), [
            "Luftfeuchte leicht feucht", "Niederschlag der letzten 72 Stunden 62,5 Millimeter"
        ])
        XCTAssertEqual(d.koppen, "Dfb")
        XCTAssertEqual(d.altitudinalBelt, "submontan-kollin")
    }

    /// After a pull the row holds the server's new answer while the
    /// stored features still belong to the previous one (they are
    /// fetched afterwards, and that can fail). Their text
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
        XCTAssertEqual(d.temperature, "16,0\u{00A0}°C", "the values themselves are the row's and stay")
        XCTAssertTrue(ConditionsDetailModel(sample: s, night: false, features: rows).isEmpty)
    }

    // MARK: - partial answers

    private func partial(_ features: String, allDay: Bool = false) throws -> ConditionsDisplay {
        var base = try sample()
        base.isAllDay = allDay
        let json = "{\"features\": [\(features)], \"providers\": []}"
        let (s, rows) = try answered(base, json: json)
        return ConditionsDisplay(sample: s, night: false, features: rows)
    }

    private let license = "\"license\": {\"name\": \"CC-BY 4.0\", \"attribution\": \"Quelle\"}"

    /// Dew point and percentage: „schwül (85 %)“.
    func testPartial_HumidityWithDewPoint() throws {
        let d = try partial(#"""
        {"properties": {"kind": "weather", "relativeHumidity2m": 85}, \#(license)},
        {"properties": {"kind": "dewpoint", "dewPoint2m": 19}, \#(license)}
        """#)
        XCTAssertEqual(d.tiles.first?.value, "85")
        XCTAssertEqual(d.tiles.first?.word, "schwül")
        XCTAssertEqual(d.tiles.first?.spoken, "Luftfeuchte schwül, 85 Prozent")
    }

    /// The force fits the km/h shown: 19,6 km/h reads as 20 km/h, and
    /// 20 km/h is force 4.
    func testPartial_WindForceFromShownSpeed() throws {
        let d = try partial(#"{"properties": {"kind": "weather", "windSpeed10m": 19.6}, \#(license)}"#)
        XCTAssertEqual(d.tiles.first?.value, "20")
        XCTAssertEqual(d.tiles.first?.word, "mäßige Brise")
    }

    func testPartial_FullMoonSymbol() throws {
        let d = try partial(#"{"properties": {"kind": "moon", "phase": {"de": "Vollmond"}, "illuminationPct": 99.6}, \#(license)}"#)
        XCTAssertEqual(d.moonSymbol, "moonphase.full.moon")
    }

    /// The illuminated part without a phase text is still shown.
    func testPartial_MoonIlluminationWithoutPhase() throws {
        let d = try partial(#"{"properties": {"kind": "moon", "illuminationPct": 43.2}, \#(license)}"#)
        XCTAssertEqual(d.moon?.value, "43\u{00A0}% beleuchtet")
        XCTAssertEqual(d.moon?.spoken, "Mond: 43 Prozent beleuchtet")
        XCTAssertEqual(d.moonSymbol, "moon", "no phase, no phase symbol")
    }

    /// The code alone is weather for this instant: no „Keine Daten“.
    func testPartial_CodeOnlyIsNoMissingData() throws {
        let d = try partial(#"{"properties": {"kind": "weather", "weatherCode": 3}, \#(license)}"#)
        XCTAssertEqual(d.weatherTitle, "Bedeckt")
        XCTAssertNil(d.note)
    }

    /// An all-day sample shows day values. A final answer without any
    /// says so, as a sample with a time of day does for its weather.
    func testPartial_AllDayWithoutDayValuesSaysSo() throws {
        let moonOnly = #"{"properties": {"kind": "moon", "phase": {"de": "Neumond"}}, \#(license)}"#
        XCTAssertEqual(try partial(moonOnly, allDay: true).note, "Keine Wetterdaten für diesen Tag")
        // Hourly weather alone does not count for a day.
        let hourlyOnly = #"{"properties": {"kind": "weather", "temperature2m": 16}, \#(license)}"#
        XCTAssertEqual(try partial(hourlyOnly, allDay: true).note, "Keine Wetterdaten für diesen Tag")
        let withDay = #"{"properties": {"kind": "aggregate", "precipitation": {"last24h": 0}}, \#(license)}"#
        XCTAssertNil(try partial(withDay, allDay: true).note)
    }

    // MARK: - sun and moon by the date

    private func skyDisplay(_ phase: ConditionsDisplay.LightPhase?) -> ConditionsDisplay {
        var d = ConditionsDisplay(state: .values)
        d.sunrise = "07:31"
        d.sunset = "16:42"
        d.moon = LabeledValue(id: "moon", label: "Mond", value: "Vollmond, 98\u{00A0}%", spoken: "Mond: Vollmond, 98 Prozent beleuchtet")
        d.moonSymbol = "moonphase.full.moon"
        d.lightPhase = phase
        return d
    }

    func testSkyItems_ByLightPhase() {
        XCTAssertEqual(skyDisplay(.day).skyItems.map(\.id), ["sunrise", "sunset"])
        XCTAssertEqual(skyDisplay(.twilight).skyItems.map(\.id), ["sunrise", "sunset", "moon"])
        XCTAssertEqual(skyDisplay(.night).skyItems.map(\.id), ["moon"])
        XCTAssertEqual(skyDisplay(nil).skyItems.map(\.id), ["sunrise", "sunset", "moon"], "unknown phase: all there is")
    }

    func testSkyItems_SymbolsAndSpeech() {
        let items = skyDisplay(.twilight).skyItems
        XCTAssertEqual(items.map(\.symbol), ["sunrise", "sunset", "moonphase.full.moon"])
        XCTAssertEqual(items.map(\.value), ["07:31", "16:42", "Vollmond, 98\u{00A0}%"])
        XCTAssertEqual(items.map(\.spoken), [
            "Sonnenaufgang 07:31 Uhr", "Sonnenuntergang 16:42 Uhr", "Mond: Vollmond, 98 Prozent beleuchtet"
        ])
    }

    // MARK: - light phase

    /// One day in UTC: nautical dawn 03:00, civil dawn 03:40, sunrise
    /// 04:20, sunset 20:00, civil dusk 20:40, nautical dusk 21:30.
    private func phase(at hhmm: String, twilight: Bool = true, nautical: Bool = true) -> ConditionsDisplay.LightPhase? {
        func t(_ v: String) -> Date {
            // swiftlint:disable:next force_unwrapping
            ISO8601DateFormatter().date(from: "2026-05-19T\(v):00Z")!
        }
        return ConditionsDisplay.lightPhase(
            at: t(hhmm), sunrise: t("04:20"), sunset: t("20:00"),
            civilDawn: twilight ? t("03:40") : nil, civilDusk: twilight ? t("20:40") : nil,
            nauticalDawn: twilight && nautical ? t("03:00") : nil, nauticalDusk: twilight && nautical ? t("21:30") : nil
        )
    }

    func testLightPhase_DayLastsThroughCivilTwilight() {
        XCTAssertEqual(phase(at: "12:00"), .day)
        XCTAssertEqual(phase(at: "03:50"), .day, "after civil dawn, before sunrise")
        XCTAssertEqual(phase(at: "20:30"), .day, "after sunset, before civil dusk")
    }

    func testLightPhase_TwilightIsNauticalTwilight() {
        XCTAssertEqual(phase(at: "03:20"), .twilight, "morning")
        XCTAssertEqual(phase(at: "21:00"), .twilight, "evening")
    }

    func testLightPhase_NightFromAstronomicalTwilight() {
        XCTAssertEqual(phase(at: "02:00"), .night)
        XCTAssertEqual(phase(at: "23:00"), .night)
    }

    /// No nautical dusk while civil dusk exists: the sun stays above
    /// -12° (high summer up north), so it never gets night.
    func testLightPhase_NoNauticalTimesMeansTwilight() {
        XCTAssertEqual(phase(at: "23:00", nautical: false), .twilight)
    }

    func testLightPhase_WithoutTwilightTimesSunriseAndSunsetDecide() {
        XCTAssertEqual(phase(at: "12:00", twilight: false), .day)
        XCTAssertEqual(phase(at: "20:30", twilight: false), .night)
    }

    /// Thailand, 06:30 local = 23:30 UTC: the times are those of the
    /// UTC day before (civil dawn 23:00 UTC of that day lies a day back).
    func testLightPhase_TimesOfTheNeighbouringUTCDay() {
        func t(_ v: String) -> Date {
            // swiftlint:disable:next force_unwrapping
            ISO8601DateFormatter().date(from: v)!
        }
        let phase = ConditionsDisplay.lightPhase(
            at: t("2026-05-19T23:30:00Z"), sunrise: t("2026-05-18T23:20:00Z"), sunset: t("2026-05-19T11:40:00Z"),
            civilDawn: t("2026-05-18T22:55:00Z"), civilDusk: t("2026-05-19T12:05:00Z"),
            nauticalDawn: t("2026-05-18T22:25:00Z"), nauticalDusk: t("2026-05-19T12:35:00Z")
        )
        XCTAssertEqual(phase, .day)
        XCTAssertEqual(ConditionsDisplay.lightPhase(
            at: t("2026-05-19T23:30:00Z"), sunrise: t("2026-05-18T23:20:00Z"), sunset: t("2026-05-19T11:40:00Z"),
            civilDawn: nil, civilDusk: nil, nauticalDawn: nil, nauticalDusk: nil
        ), .day, "the sunrise/sunset fallback too")
    }

    func testLightPhase_NothingKnownIsNil() {
        XCTAssertNil(ConditionsDisplay.lightPhase(
            at: Date(), sunrise: nil, sunset: nil, civilDawn: nil, civilDusk: nil, nauticalDawn: nil, nauticalDusk: nil
        ))
    }

    func testNumber_GermanDecimalsAndNoNegativeZero() {
        XCTAssertEqual(ConditionsDisplay.number(18.44, digits: 1), "18,4")
        XCTAssertEqual(ConditionsDisplay.number(-0.04, digits: 1), "0,0")
        XCTAssertEqual(ConditionsDisplay.number(-3.75, digits: 1), "-3,8")
        XCTAssertEqual(ConditionsDisplay.number(1234.5, digits: 0), "1235")
    }
}
