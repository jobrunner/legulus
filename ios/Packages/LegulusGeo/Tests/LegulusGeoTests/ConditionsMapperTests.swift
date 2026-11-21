@testable import LegulusGeo
import XCTest

/// Counterpart of `tabularius/internal/conditions/map_test.go`: same
/// fixtures, same expected values. App and backend must map a Tempus
/// answer onto the same fields and status.
final class ConditionsMapperTests: XCTestCase {
    private let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/testdata/tempus")

    private func fixture(_ name: String) throws -> TempusResponse {
        try JSONDecoder().decode(TempusResponse.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        // swiftlint:disable:next force_unwrapping
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private var past: Date {
        utc(2026, 7, 1, 12)
    }

    private var pastFetch: Date {
        past.addingTimeInterval(30 * 24 * 3600)
    }

    private let hour: TimeInterval = 3600

    private func weatherOnly(_ props: [String: JSONValue], license: JSONValue? = .object([
        "name": .string("CC-BY 4.0"), "url": .string("https://example.org"), "attribution": .string("x")
    ])) -> TempusResponse {
        var props = props
        props["kind"] = .string("weather")
        return TempusResponse(
            features: [.init(properties: props, license: license)],
            providers: [.init(id: "open-meteo", kind: "weather", status: "ok", retryAfter: nil)]
        )
    }

    func testPastAllOk() throws {
        let r = try ConditionsMapper.map(fixture("query_past_all_ok.json"), queriedFor: past, fetchedAt: pastFetch)
        XCTAssertEqual(r.status, .final)
        XCTAssertNil(r.retryAt)
        XCTAssertEqual(r.queriedFor, past)
        XCTAssertEqual(r.fetchedAt, pastFetch)
        let want: [String: ConditionsValue] = [
            "weather_temperature_c": .number(16.0),
            "weather_humidity_pct": .number(85.0),
            "weather_dew_point_c": .number(13.5),
            "weather_precipitation_mm": .number(1.4),
            "weather_wind_speed_kmh": .number(7.4),
            "weather_cloud_cover_pct": .number(100.0),
            "weather_code": .number(61.0),
            "precipitation_24h_mm": .number(34.0),
            "precipitation_72h_mm": .number(62.5),
            "precipitation_120h_mm": .number(62.7),
            "day_temperature_min_c": .number(14.2),
            "day_temperature_max_c": .number(18.5),
            "day_temperature_mean_c": .number(17.3),
            "climate_koppen_code": .text("Dfb"),
            "climate_altitudinal_belt": .text("submontan-kollin"),
            "sunrise": .date(utc(2026, 7, 1, 3, 16, 45)),
            "sunset": .date(utc(2026, 7, 1, 19, 17, 30)),
            "moon_phase": .text("Vollmond"),
            "moon_illumination_pct": .number(97.89)
        ]
        XCTAssertEqual(r.values, want)
        XCTAssertEqual(r.fields, want.keys.sorted())
        XCTAssertEqual(r.features.count, 6)
        for f in r.features {
            XCTAssertEqual(f.sourceID, "tempus:" + f.layer)
            XCTAssertEqual(f.sourceName, "Tempus")
            XCTAssertFalse(f.propertiesJSON.isEmpty)
            XCTAssertFalse((f.licenseJSON ?? "").isEmpty)
        }
        XCTAssertEqual(Set(r.features.map(\.layer)), ["aggregate", "bioclim", "dewpoint", "moon", "sun", "weather"])
    }

    func testRecentIsProvisionalWithRetryAfter() throws {
        let fetched = past.addingTimeInterval(3 * hour)
        let r = try ConditionsMapper.map(
            fixture("query_recent_weather_unavailable.json"), queriedFor: past, fetchedAt: fetched
        )
        XCTAssertEqual(r.status, .provisional)
        XCTAssertEqual(r.retryAt, fetched.addingTimeInterval(2 * hour))
        XCTAssertEqual(r.features.map(\.layer).sorted(), ["aggregate", "bioclim", "moon", "sun"])
        XCTAssertNil(r.values["weather_temperature_c"])
    }

    func testUnavailableWithoutHintRetriesAfterOneHour() throws {
        var resp = try fixture("query_recent_weather_unavailable.json")
        for i in resp.providers.indices {
            resp.providers[i].retryAfter = nil
        }
        let fetched = past.addingTimeInterval(3 * hour)
        let r = ConditionsMapper.map(resp, queriedFor: past, fetchedAt: fetched)
        XCTAssertEqual(r.retryAt, fetched.addingTimeInterval(hour))
    }

    func testOldButUnavailableStaysProvisional() throws {
        let r = try ConditionsMapper.map(
            fixture("query_recent_weather_unavailable.json"), queriedFor: past, fetchedAt: pastFetch
        )
        XCTAssertEqual(r.status, .provisional)
        XCTAssertEqual(r.retryAt, pastFetch.addingTimeInterval(2 * hour))
    }

    func testFreshAllOkRetriesAfterFiveDays() throws {
        let r = try ConditionsMapper.map(
            fixture("query_past_all_ok.json"), queriedFor: past, fetchedAt: past.addingTimeInterval(hour)
        )
        XCTAssertEqual(r.status, .provisional)
        XCTAssertEqual(r.retryAt, past.addingTimeInterval(120 * hour))
        XCTAssertEqual(r.features.count, 6)
    }

    func testFutureKeepsSunAndMoon() throws {
        let future = utc(2027, 6, 1, 12)
        let fetched = utc(2026, 11, 19, 9)
        let r = try ConditionsMapper.map(
            fixture("query_future_weather_error.json"), queriedFor: future, fetchedAt: fetched
        )
        XCTAssertEqual(r.status, .provisional)
        XCTAssertEqual(r.retryAt, future.addingTimeInterval(hour))
        XCTAssertEqual(r.features.map(\.layer).sorted(), ["bioclim", "moon", "sun"])
        XCTAssertEqual(r.values["moon_phase"], .text("abnehmende Sichel"))
        XCTAssertEqual(r.values["moon_illumination_pct"], .number(14.19))
        XCTAssertEqual(r.values["sunrise"], .date(utc(2027, 6, 1, 3, 18, 8)))
    }

    /// 0 °C, 0 mm and 0 % are measurements, not gaps.
    func testZeroValuesCount() {
        let r = ConditionsMapper.map(weatherOnly([
            "temperature2m": .number(0), "precipitation": .number(0), "cloudCover": .number(0)
        ]), queriedFor: past, fetchedAt: pastFetch)
        XCTAssertEqual(r.fields, ["weather_cloud_cover_pct", "weather_precipitation_mm", "weather_temperature_c"])
        XCTAssertEqual(r.values["weather_temperature_c"], .number(0))
        XCTAssertNil(r.values["weather_humidity_pct"])
    }

    /// A null inside a delivered feature is a gap, not a zero.
    func testNullPropertyIsNotAField() {
        let r = ConditionsMapper.map(
            weatherOnly(["temperature2m": .null, "precipitation": .number(2.5)]),
            queriedFor: past, fetchedAt: pastFetch
        )
        XCTAssertEqual(r.fields, ["weather_precipitation_mm"])
    }

    func testWindInOtherUnitIsNotStored() {
        let r = ConditionsMapper.map(weatherOnly([
            "windSpeed10m": .number(4.2), "units": .object(["windSpeed10m": .string("m/s")])
        ]), queriedFor: past, fetchedAt: pastFetch)
        XCTAssertTrue(r.fields.isEmpty, "wind in m/s must not land in the km/h column")
        XCTAssertEqual(r.features.count, 1, "the feature itself must be kept")
    }

    func testDropsFeatureWithoutLicenseOrKind() {
        var resp = weatherOnly(["temperature2m": .number(3)], license: nil)
        resp.features.append(.init(
            properties: ["temperature2m": .number(5)], license: .object(["name": .string("n")])
        ))
        resp.features.append(.init(
            properties: ["kind": .string("sun"), "sunrise": .string("2026-07-01T03:16:45Z")], license: .object([:])
        ))
        let r = ConditionsMapper.map(resp, queriedFor: past, fetchedAt: pastFetch)
        XCTAssertTrue(r.features.isEmpty)
        XCTAssertTrue(r.values.isEmpty)
    }

    func testProviderErrorIsFinal() throws {
        var resp = try fixture("query_past_all_ok.json")
        resp.features.removeAll { $0.kind == "bioclim" }
        for i in resp.providers.indices where resp.providers[i].id == "bioclim" {
            resp.providers[i].status = "error"
        }
        let r = ConditionsMapper.map(resp, queriedFor: past, fetchedAt: pastFetch)
        XCTAssertEqual(r.status, .final)
        XCTAssertNil(r.retryAt)
        XCTAssertFalse(r.features.contains { $0.layer == "bioclim" })
    }

    /// Unknown properties stay in the stored feature.
    func testFeatureKeepsUnknownProperties() {
        let r = ConditionsMapper.map(
            weatherOnly(["temperature2m": .number(3), "brandNew": .object(["x": .number(1)])]),
            queriedFor: past, fetchedAt: pastFetch
        )
        XCTAssertTrue(r.features.first?.propertiesJSON.contains("\"brandNew\":{\"x\":1}") ?? false)
    }

    /// A member of the wrong type is a broken answer. Read as "no
    /// features, no providers" it would map to a final result without
    /// data for an old sample, and nobody would ask again.
    func testMalformedAnswerDoesNotDecode() {
        func decode(_ json: String) throws -> TempusResponse {
            try JSONDecoder().decode(TempusResponse.self, from: Data(json.utf8))
        }
        XCTAssertThrowsError(try decode(#"{"features": "nope", "providers": []}"#))
        XCTAssertThrowsError(try decode(#"{"features": [], "providers": {"id": "sun"}}"#))
        XCTAssertThrowsError(try decode(#"{"features": [{"properties": 5}], "providers": []}"#))
        XCTAssertThrowsError(try decode(#"{"features": [], "providers": [{"id": "sun", "status": 1}]}"#))
        // Missing or null members are an empty answer, not a broken one.
        XCTAssertEqual(try decode("{}").features.count, 0)
        XCTAssertEqual(try decode(#"{"features": null, "providers": null}"#).providers.count, 0)
        XCTAssertEqual(
            try decode(#"{"features": [{"properties": {"kind": "sun"}, "license": null}]}"#).features.first?.kind,
            "sun"
        )
    }

    /// Tempus sends retryAfter as a Go duration.
    func testGoDuration() {
        XCTAssertEqual(TempusResponse.Provider.goDuration("2h0m0s"), 7200)
        XCTAssertEqual(TempusResponse.Provider.goDuration("1h30m"), 5400)
        XCTAssertEqual(TempusResponse.Provider.goDuration("45s"), 45)
        XCTAssertEqual(TempusResponse.Provider.goDuration("1.5s"), 1.5)
        XCTAssertNil(TempusResponse.Provider.goDuration(""))
        XCTAssertNil(TempusResponse.Provider.goDuration("soon"))
        XCTAssertNil(TempusResponse.Provider.goDuration("0s"))
        XCTAssertNil(TempusResponse.Provider.goDuration("-5m"))
    }

    func testValueFieldsAreTheBackendColumns() {
        XCTAssertEqual(ConditionsMapper.valueFields.count, 19)
        XCTAssertEqual(ConditionsMapper.valueFields.first, "weather_temperature_c")
        XCTAssertEqual(ConditionsMapper.valueFields.last, "moon_illumination_pct")
    }
}
