import GRDB
@testable import Legulus
import LegulusGeo
import XCTest

final class SampleConditionsTests: XCTestCase {
    private func utc(_ iso: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(f.date(from: iso))
    }

    private func serverSample(_ extra: [String: Any]) throws -> Sample {
        var dict: [String: Any] = [
            "id": "backend-1", "sample_id": "260519/1", "fieldtrip": "ft-1",
            "latitude": 49.68, "longitude": 10.04, "timezone": "Europe/Berlin", "version": 1
        ]
        dict.merge(extra) { _, new in new }
        return try JSONDecoder.legulus.decode(Sample.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func result(_ values: [String: ConditionsValue], status: ConditionsStatus = .final) throws -> ConditionsResult {
        try ConditionsResult(
            status: status, queriedFor: utc("2026-07-01T12:00:00Z"), fetchedAt: utc("2026-07-31T12:00:00Z"),
            retryAt: status == .final ? nil : utc("2026-07-06T12:00:00Z"), values: values, features: []
        )
    }

    /// PocketBase has no empty number: an undelivered value reads 0. A
    /// column counts only when `conditions_fields` lists it.
    func testServer_ZeroCountsOnlyWhenListed() throws {
        let sample = try serverSample([
            "conditions_status": "final",
            "conditions_fields": ["weather_temperature_c", "climate_koppen_code", "sunrise"],
            "conditions_queried_for": "2026-07-01 12:00:00.000Z",
            "conditions_fetched_at": "2026-07-31 12:00:00.000Z",
            "conditions_retry_at": "",
            "weather_temperature_c": 0, "weather_humidity_pct": 0,
            "climate_koppen_code": "Dfb", "moon_phase": "",
            "sunrise": "2026-07-01 03:16:45.000Z"
        ])
        let c = try XCTUnwrap(sample.conditions)
        XCTAssertEqual(c.status, .final)
        XCTAssertEqual(c.number("weather_temperature_c"), 0)
        XCTAssertNil(c.number("weather_humidity_pct"))
        XCTAssertEqual(c.text("climate_koppen_code"), "Dfb")
        XCTAssertEqual(c.date("sunrise"), try utc("2026-07-01T03:16:45Z"))
        XCTAssertEqual(c.queriedFor, try utc("2026-07-01T12:00:00Z"))
        XCTAssertNil(c.retryAt)
        XCTAssertEqual(c.fields, ["climate_koppen_code", "sunrise", "weather_temperature_c"])
    }

    func testServer_EmptyStatusIsNoConditions() throws {
        XCTAssertNil(try serverSample([:]).conditions)
        XCTAssertNil(try serverSample(["conditions_status": ""]).conditions)
    }

    func testServer_PendingHasNoValues() throws {
        let c = try XCTUnwrap(serverSample(["conditions_status": "pending", "weather_temperature_c": 0]).conditions)
        XCTAssertEqual(c, .pending)
    }

    /// What the app sends must read back as what it holds — the backend
    /// keeps delivered values as they are.
    func testWireBody_RoundTripsThroughTheServerModel() throws {
        let mine = try SampleConditions(result([
            "weather_temperature_c": .number(0), "weather_wind_speed_kmh": .number(7.4),
            "climate_koppen_code": .text("Dfb"), "sunset": .date(utc("2026-07-01T19:17:30Z"))
        ], status: .provisional))
        let body = mine.wireBody
        XCTAssertEqual(body["conditions_status"] as? String, "provisional")
        XCTAssertEqual(body["conditions_fields"] as? [String], mine.fields)
        // Columns Tempus did not deliver are reset, so nothing from an
        // earlier answer stays in them.
        XCTAssertEqual(body["weather_humidity_pct"] as? Double, 0)
        XCTAssertEqual(body["moon_phase"] as? String, "")
        XCTAssertEqual(body["sunrise"] as? String, "")
        XCTAssertEqual(try serverSample(body).conditions, mine)
    }

    /// A pending sample has nothing to deliver; the backend decides.
    func testWireBody_EmptyWithoutValues() {
        XCTAssertTrue(SampleConditions.pending.wireBody.isEmpty)
    }

    func testLocalRoundTrip_KeepsZeroAndDates() throws {
        let database = try Database(inMemory: ())
        let store = LocalSampleStore(
            database: database, userId: "u1", timeZone: .gmt, settings: { SampleIDSettings(cutoffHour: 5) }
        )
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: utc("2026-07-01T12:00:00Z"))
        XCTAssertNil(sample.conditions)
        let mine = try SampleConditions(result([
            "weather_temperature_c": .number(0), "moon_phase": .text("Vollmond"),
            "sunrise": .date(utc("2026-07-01T03:16:45Z"))
        ]))
        sample.conditions = mine
        try store.update(sample)
        XCTAssertEqual(try store.fetchById(sample.id)?.conditions, mine)
    }
}
