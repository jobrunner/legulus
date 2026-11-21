@testable import Legulus
import LegulusGeo
import XCTest

/// Ortus and Tempus features share one table but are replaced
/// separately: an Ortus answer must not delete the weather features of
/// a sample, and the other way round.
final class LocalSampleFeatureStoreScopeTests: XCTestCase {
    private var store: LocalSampleFeatureStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try LocalSampleFeatureStore(database: Database(inMemory: ()))
    }

    private func ortus(_ id: String) -> OrtusFeature {
        OrtusFeature(sourceID: "wdpa", sourceName: "WDPA", layer: "areas", featureID: id,
                     propertiesJSON: "{}", licenseJSON: nil)
    }

    private func tempus(_ kind: String) -> OrtusFeature {
        OrtusFeature(sourceID: "tempus:" + kind, sourceName: "Tempus", layer: kind, featureID: "",
                     propertiesJSON: "{\"kind\":\"\(kind)\"}", licenseJSON: "{\"name\":\"CC-BY 4.0\"}")
    }

    func testScopeOfSourceID() {
        XCTAssertTrue(FeatureScope.tempus.contains(sourceID: "tempus:weather"))
        XCTAssertFalse(FeatureScope.tempus.contains(sourceID: "wdpa"))
        XCTAssertTrue(FeatureScope.ortus.contains(sourceID: "wdpa"))
        XCTAssertFalse(FeatureScope.ortus.contains(sourceID: "tempus:sun"))
        XCTAssertEqual(FeatureScope.ortus.rawValue, "ortus")
        XCTAssertEqual(FeatureScope.tempus.rawValue, "tempus")
    }

    func testReplace_TouchesOnlyItsScope() throws {
        try store.replace(sampleID: "s", scope: .ortus, features: [ortus("1"), ortus("2")])
        try store.replace(sampleID: "s", scope: .tempus, features: [tempus("sun"), tempus("moon")])
        XCTAssertEqual(try store.count(sampleID: "s", scope: .ortus), 2)
        XCTAssertEqual(try store.count(sampleID: "s", scope: .tempus), 2)

        try store.replace(sampleID: "s", scope: .ortus, features: [ortus("3")])
        XCTAssertEqual(try store.all(sampleID: "s", scope: .ortus).map(\.featureID), ["3"])
        XCTAssertEqual(try store.all(sampleID: "s", scope: .tempus).map(\.layer), ["sun", "moon"])

        try store.replace(sampleID: "s", scope: .tempus, features: [])
        XCTAssertEqual(try store.count(sampleID: "s", scope: .tempus), 0)
        XCTAssertEqual(try store.count(sampleID: "s", scope: .ortus), 1)
    }

    /// A feature of the other source in the list is not stored: the
    /// scope decides, not the caller's list.
    func testReplace_IgnoresFeaturesOfTheOtherScope() throws {
        try store.replace(sampleID: "s", scope: .ortus, features: [ortus("1"), tempus("sun")])
        XCTAssertEqual(try store.count(sampleID: "s", scope: .ortus), 1)
        XCTAssertEqual(try store.count(sampleID: "s", scope: .tempus), 0)
    }

    func testReplaceRequest_CarriesTheScope() throws {
        let client = SampleFeaturesClient(endpoint: "https://backend.example")
        try store.replace(sampleID: "s", scope: .tempus, features: [tempus("sun")])
        let rows = try store.all(sampleID: "s", scope: .tempus)
        let request = try client.replaceRequest(sampleBackendID: "abc123", scope: .tempus, features: rows)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://backend.example/api/samples/abc123/features?scope=tempus")
        let ortusRequest = try client.replaceRequest(sampleBackendID: "abc123", scope: .ortus, features: [])
        XCTAssertEqual(ortusRequest.url?.query, "scope=ortus")
    }
}
