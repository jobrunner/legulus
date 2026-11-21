@testable import Legulus
import LegulusGeo
import XCTest

final class ConditionsDetailModelTests: XCTestCase {
    private var store: LocalSampleStore!
    /// 2026-07-01 12:00 UTC.
    private let begin = Date(timeIntervalSince1970: 1_782_907_200)

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try LocalSampleStore(
            database: Database(inMemory: ()), userId: "u1", timeZone: .gmt,
            settings: { SampleIDSettings(cutoffHour: 5) }
        )
    }

    private let answer = """
    {"features": [
      {"properties": {"kind": "sun", "sunrise": "2026-07-01T03:16:45Z", "dayLengthMinutes": 960.76,
                      "twilight": {"civil": {"dawn": "2026-07-01T02:35:32Z"}},
                      "lightPhase": {"de": "Tag", "en": "day"}, "units": {"dayLengthMinutes": "min"},
                      "provider": "sun"},
       "license": {"name": "NOAA Solar Calculator", "url": "https://example.org/noaa", "attribution": "NOAA"}},
      {"properties": {"kind": "weather", "temperature2m": 16, "isDay": true, "brandNew": {"depth": 3.5},
                      "weatherCodeDescription": {"de": "Leichter Regen"}, "units": {"temperature2m": "°C"}},
       "license": {"name": "CC-BY 4.0", "url": "https://example.org/cc", "attribution": "Quelle A"}},
      {"properties": {"kind": "dewpoint", "dewPoint2m": 13.5, "units": {"dewPoint2m": "°C"}},
       "license": {"name": "CC-BY 4.0", "attribution": "Quelle A"}},
      {"properties": {"kind": "bioclim", "koppen": {"code": "Dfb", "de": "kontinental", "en": "continental"}, "bio": {"bio1": 8.9}},
       "license": {"name": "CC-BY 4.0", "attribution": "Quelle B"}}
    ], "providers": []}
    """

    private func model(zone: String = "Europe/Berlin", change: (inout LocalSample) -> Void = { _ in }) throws
        -> ConditionsDetailModel
    {
        var s = try store.createLocal(lat: 48.13, lon: 11.58, elevation: 520, collectedFrom: begin)
        s.timezone = zone
        let request = try XCTUnwrap(ConditionsRequest(s, night: false))
        let result = ConditionsMapper.map(
            TempusFixtures.response(answer), queriedFor: request.instant,
            fetchedAt: request.instant.addingTimeInterval(40 * 86400)
        )
        var conditions = SampleConditions(result)
        conditions.inputs = request.inputs
        s.conditions = conditions
        let rows = result.features.map { LocalSampleFeature(sampleID: s.id, feature: $0, fetchedAt: result.fetchedAt) }
        change(&s)
        return ConditionsDetailModel(sample: s, night: false, features: rows)
    }

    private func row(_ model: ConditionsDetailModel, _ group: String, _ label: String) -> String? {
        model.groups.first { $0.id == group }?.rows.first { $0.label == label }?.value
    }

    /// Fixed order of subjects whatever order Tempus sends; a subject
    /// without feature is left out.
    func testGroups_OrderAndMissingSubjects() throws {
        let m = try model()
        XCTAssertEqual(m.groups.map(\.id), ["weather", "climate", "sun"])
        XCTAssertEqual(m.groups.map(\.title), ["Wetter", "Klima", "Sonne"])
    }

    func testRows_NamesUnitsAndGermanTexts() throws {
        let m = try model()
        XCTAssertEqual(row(m, "weather", "Temperatur"), "16\u{00A0}°C")
        XCTAssertEqual(row(m, "weather", "Taupunkt"), "13,5\u{00A0}°C", "the dew point belongs to the weather")
        XCTAssertEqual(row(m, "weather", "Wetter"), "Leichter Regen")
        XCTAssertEqual(row(m, "weather", "Tag"), "ja")
        XCTAssertEqual(row(m, "climate", "Köppen-Geiger"), "Dfb")
        XCTAssertEqual(row(m, "climate", "Klimatyp"), "kontinental")
        XCTAssertNil(row(m, "climate", "koppen.en"), "one language is enough")
        XCTAssertEqual(row(m, "sun", "Tageslänge"), "960,76\u{00A0}min")
        XCTAssertEqual(row(m, "sun", "Lichtphase"), "Tag")
    }

    /// Known properties first in the page order, unknown ones after
    /// them under their own name — nothing Tempus sends is dropped.
    func testRows_UnknownPropertiesAreListedGenerically() throws {
        let m = try model()
        XCTAssertEqual(row(m, "weather", "brandNew.depth"), "3,5")
        XCTAssertEqual(row(m, "climate", "bio.bio1"), "8,9")
        let labels = try XCTUnwrap(m.groups.first { $0.id == "weather" }?.rows.map(\.label))
        XCTAssertEqual(labels, ["Wetter", "Temperatur", "Taupunkt", "Tag", "brandNew.depth"])
        XCTAssertNil(row(m, "sun", "provider"), "bookkeeping keys are no values")
        XCTAssertNil(row(m, "sun", "kind"))
    }

    func testTimes_InTheSamplesZone() throws {
        let berlin = try model()
        XCTAssertEqual(row(berlin, "sun", "Sonnenaufgang"), "01.07.2026 05:16")
        XCTAssertEqual(row(berlin, "sun", "Bürgerliche Dämmerung, Beginn"), "01.07.2026 04:35")
        XCTAssertEqual(berlin.queriedFor, "01.07.2026 14:00")
        let canary = try model(zone: "Atlantic/Canary")
        XCTAssertEqual(row(canary, "sun", "Sonnenaufgang"), "01.07.2026 04:16")
    }

    func testSources_PerGroup() throws {
        let m = try model()
        let weather = try XCTUnwrap(m.groups.first { $0.id == "weather" })
        XCTAssertEqual(weather.attribution, "Quelle A", "weather and dew point share one source: once")
        XCTAssertEqual(weather.licenseName, "CC-BY 4.0")
        XCTAssertEqual(weather.licenseURL?.absoluteString, "https://example.org/cc")
        let sun = try XCTUnwrap(m.groups.first { $0.id == "sun" })
        XCTAssertEqual(sun.attribution, "NOAA")
        XCTAssertEqual(m.elevationNote, "Werte für 520 m über dem Meer")
        XCTAssertFalse(m.isProvisional)
    }

    /// Values that no longer fit the sample have no detail page.
    func testStaleValues_Empty() throws {
        XCTAssertTrue(try model { $0.elevation = 900 }.isEmpty)
    }
}
