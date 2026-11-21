@testable import Legulus
import LegulusGeo
import XCTest

@MainActor
final class SampleConditionsResolverTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var features: LocalSampleFeatureStore!
    private var tempus: StubTempus!
    /// 2026-06-30 12:00 UTC — six weeks after the samples: answers are final.
    private let now = Date(timeIntervalSince1970: 1_782_820_800)
    /// 2026-05-19 12:00 UTC.
    private let begin = Date(timeIntervalSince1970: 1_779_192_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(
            database: database, userId: "u1", timeZone: .gmt, settings: { SampleIDSettings(cutoffHour: 5) }
        )
        features = LocalSampleFeatureStore(database: database)
        tempus = StubTempus()
    }

    private func resolver(night: Bool = false, tempus: TempusQuerying?? = .none) -> SampleConditionsResolver {
        SampleConditionsResolver(
            tempus: tempus ?? self.tempus, samples: samples, features: features,
            isNightFieldtrip: { _ in night }, now: { [now] in now }
        )
    }

    private func sample(elevation: Double? = 519.6) throws -> LocalSample {
        try samples.createLocal(lat: 49.681616, lon: 10.039652, elevation: elevation, collectedFrom: begin)
    }

    private func stored(_ id: String) throws -> LocalSample {
        try XCTUnwrap(samples.fetchById(id))
    }

    func testResolve_WritesValuesAndWeatherFeatures() async throws {
        let s = try sample()
        let wrote = await resolver().resolve(sampleID: s.id)
        XCTAssertTrue(wrote)

        XCTAssertEqual(tempus.queries, [.init(lat: 49.681616, lon: 10.039652, elevationMetres: 520, at: begin)])
        let c = try XCTUnwrap(stored(s.id).conditions)
        XCTAssertEqual(c.status, .final)
        XCTAssertEqual(c.queriedFor, begin)
        XCTAssertEqual(c.fetchedAt, now)
        XCTAssertEqual(c.number("weather_temperature_c"), 0, "0 °C is a value")
        XCTAssertEqual(c.text("moon_phase"), "Neumond")
        XCTAssertNil(c.number("weather_cloud_cover_pct"))
        XCTAssertTrue(c.needsPush, "the server does not have them yet")
        XCTAssertEqual(try features.all(sampleID: s.id, scope: .tempus).map(\.sourceID),
                       ["tempus:weather", "tempus:sun", "tempus:moon"])
    }

    /// Tempus requires the height: without a usable one nothing is asked.
    func testResolve_NothingToAskWith() async throws {
        let noHeight = try sample(elevation: nil)
        var tooHigh = try sample()
        tooHigh.elevation = 9500
        try samples.update(tooHigh)
        var noCoordinate = try sample()
        noCoordinate.latitude = nil
        noCoordinate.longitude = nil
        try samples.update(noCoordinate)

        for id in [noHeight.id, tooHigh.id, noCoordinate.id] {
            let wrote = await resolver().resolve(sampleID: id)
            XCTAssertFalse(wrote)
            XCTAssertNil(try stored(id).conditions)
        }
        let wrote = try await resolver(tempus: .some(nil)).resolve(sampleID: sample().id)
        XCTAssertFalse(wrote, "an empty endpoint switches the query off")
        XCTAssertTrue(tempus.queries.isEmpty)
    }

    /// The app does not ask again for values that fit the sample; the
    /// backend's job refreshes provisional ones.
    func testResolve_ValuesThatFitAreNotAskedAgain() async throws {
        let s = try sample()
        _ = await resolver().resolve(sampleID: s.id)
        let again = await resolver().resolve(sampleID: s.id)
        XCTAssertFalse(again)
        XCTAssertEqual(tempus.queries.count, 1)
    }

    /// Values belong to the coordinate, the height (whole metres) and
    /// the instant they were queried with.
    func testValidConditions_FollowTheSample() async throws {
        let s = try sample()
        let r = resolver()
        _ = await r.resolve(sampleID: s.id)
        XCTAssertNotNil(try r.validConditions(for: stored(s.id)))

        var sameMetre = try stored(s.id)
        sameMetre.elevation = 520.4
        sameMetre.notes = "Eichenstubben"
        XCTAssertNotNil(r.validConditions(for: sameMetre), "GPS noise below a metre changes nothing")

        var higher = try stored(s.id)
        higher.elevation = 800
        XCTAssertNil(r.validConditions(for: higher))

        var moved = try stored(s.id)
        moved.latitude = 49.7
        XCTAssertNil(r.validConditions(for: moved))

        var later = try stored(s.id)
        later.beginDate = begin.addingTimeInterval(3600)
        XCTAssertNil(r.validConditions(for: later))

        var noHeight = try stored(s.id)
        noHeight.elevationSource = nil
        XCTAssertNil(r.validConditions(for: noHeight))
    }

    func testResolve_AsksAgainAfterTheSampleMoved() async throws {
        let s = try sample()
        _ = await resolver().resolve(sampleID: s.id)
        var moved = try stored(s.id)
        moved.elevation = 800
        try samples.update(moved)

        let wrote = await resolver().resolve(sampleID: s.id)
        XCTAssertTrue(wrote)
        XCTAssertEqual(tempus.queries.map(\.elevationMetres), [520, 800])
    }

    /// The sample changed while Tempus answered: the answer no longer
    /// fits and is dropped.
    func testResolve_DropsTheAnswerWhenTheSampleChangedMeanwhile() async throws {
        let s = try sample()
        tempus.duringQuery = { [samples] in
            guard var row = try? samples?.fetchById(s.id) else { return }
            row.elevation = 800
            try? samples?.update(row)
        }
        let wrote = await resolver().resolve(sampleID: s.id)
        XCTAssertFalse(wrote)
        XCTAssertNil(try stored(s.id).conditions)
        XCTAssertEqual(try features.count(sampleID: s.id, scope: .tempus), 0)
    }

    /// The sync left the account while Tempus answered: the answer
    /// is not written (the next session's data must not be touched).
    func testResolve_NotLiveAnyMoreWritesNothing() async throws {
        let s = try sample()
        let wrote = await resolver().resolve(sampleID: s.id) { false }
        XCTAssertFalse(wrote)
        XCTAssertEqual(tempus.queries.count, 1)
        XCTAssertNil(try stored(s.id).conditions)
        XCTAssertEqual(try features.count(sampleID: s.id, scope: .tempus), 0)
    }

    /// The backend counts a coordinate change above 1e-7 as a move and
    /// resets the values; the app must ask again then, or the push
    /// would carry none.
    func testValidConditions_UseTheBackendsCoordinateTolerance() async throws {
        let s = try sample()
        let r = resolver()
        _ = await r.resolve(sampleID: s.id)
        var noise = try stored(s.id)
        noise.latitude = 49.681616 + 5e-8
        XCTAssertNotNil(r.validConditions(for: noise))
        var moved = try stored(s.id)
        moved.latitude = 49.681616 + 5e-7
        XCTAssertNil(r.validConditions(for: moved))
    }

    /// A corrected coordinate removes the Ortus features of the old
    /// point. The weather features stay with the weather values:
    /// corrected back before the sync, values and features still fit,
    /// and nothing would fetch the features again.
    func testCoordinateCorrection_KeepsWeatherFeaturesWithTheirValues() async throws {
        let s = try sample()
        try features.replace(sampleID: s.id, scope: .ortus, features: [
            OrtusFeature(sourceID: "wdpa", sourceName: "WDPA", layer: "areas", featureID: "1",
                         propertiesJSON: "{}", licenseJSON: nil)
        ])
        let r = resolver()
        _ = await r.resolve(sampleID: s.id)
        let mutations = PendingMutationsStore(database: database)

        try samples.updateCoordinate(id: s.id, latitude: 50.0, longitude: 10.0, mutationsStore: mutations)
        XCTAssertEqual(try features.count(sampleID: s.id, scope: .ortus), 0)
        XCTAssertNil(try r.validConditions(for: stored(s.id)), "moved: the values no longer count")

        try samples.updateCoordinate(id: s.id, latitude: 49.681616, longitude: 10.039652, mutationsStore: mutations)
        XCTAssertNotNil(try r.validConditions(for: stored(s.id)), "back at the place they were fetched for")
        XCTAssertEqual(try features.count(sampleID: s.id, scope: .tempus), 3)
    }

    func testResolve_FailureWritesNothing() async throws {
        let s = try sample()
        tempus.result = .failure(URLError(.timedOut))
        let wrote = await resolver().resolve(sampleID: s.id)
        XCTAssertFalse(wrote)
        XCTAssertNil(try stored(s.id).conditions)
    }

    /// All-day: 14:00 local, 22:00 in a night fieldtrip.
    func testResolve_AllDayInstant() async throws {
        var s = try sample()
        s.isAllDay = true
        s.timezone = "Europe/Berlin"
        try samples.update(s)

        _ = await resolver(night: false).resolve(sampleID: s.id)
        _ = await resolver(night: true).resolve(sampleID: s.id)
        // 2026-05-19 in Berlin (UTC+2): 14:00 = 12:00Z, 22:00 = 20:00Z.
        XCTAssertEqual(tempus.queries.map(\.at), [begin, begin.addingTimeInterval(8 * 3600)])
    }

    /// Values and features are one unit: when the sample no longer is
    /// what they were fetched for, neither is written.
    func testWriteConditions_AbortWritesNeitherValuesNorFeatures() throws {
        let s = try sample()
        let feature = OrtusFeature(sourceID: "tempus:sun", sourceName: "Tempus", layer: "sun", featureID: "",
                                   propertiesJSON: "{}", licenseJSON: "{\"name\":\"x\"}")
        let wrote = try samples.writeConditions(id: s.id, features: [feature]) { row in
            row.conditions = .pending
            return false
        }
        XCTAssertFalse(wrote)
        XCTAssertNil(try stored(s.id).conditions)
        XCTAssertEqual(try features.count(sampleID: s.id, scope: .tempus), 0)

        XCTAssertTrue(try samples.writeConditions(id: s.id, features: [feature]) { row in
            row.conditions = .pending
            return true
        })
        XCTAssertEqual(try stored(s.id).conditions, .pending)
        XCTAssertEqual(try features.count(sampleID: s.id, scope: .tempus), 1)
    }

    func testResolve_RemembersWhichAnswerTheFeaturesBelongTo() async throws {
        let s = try sample()
        _ = await resolver().resolve(sampleID: s.id)
        XCTAssertEqual(try stored(s.id).conditions?.featuresFetchedAt, now)
    }

    /// The Ortus features of the sample are not touched.
    func testResolve_LeavesOrtusFeatures() async throws {
        let s = try sample()
        try features.replace(sampleID: s.id, scope: .ortus, features: [
            OrtusFeature(sourceID: "wdpa", sourceName: "WDPA", layer: "areas", featureID: "1",
                         propertiesJSON: "{}", licenseJSON: nil)
        ])
        _ = await resolver().resolve(sampleID: s.id)
        XCTAssertEqual(try features.count(sampleID: s.id, scope: .ortus), 1)
    }
}
