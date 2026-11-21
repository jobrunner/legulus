@testable import Legulus
import LegulusGeo
import XCTest

/// The contract between app and backend for weather values, against the
/// real test instance: what the app delivers with a create must be what
/// the backend stores (it takes delivered values over when they fit the
/// sample), and the weather features must land under their scope.
/// Tempus itself is stubbed; the test instance has none configured, so
/// whatever the server holds afterwards came from the app.
@MainActor
final class ConditionsBackendContractTests: XCTestCase {
    private final class Token: AuthTokenSource {
        let currentToken: String?
        init(_ token: String) { currentToken = token }
    }

    private var endpoint: String {
        Bundle.main.object(forInfoDictionaryKey: "TABULARIUS_ENDPOINT_DEFAULT") as? String ?? ""
    }

    /// Signs in as the test user of `scripts/reset-test-tabularius.sh`.
    private func signIn() async throws -> Token {
        let url = try XCTUnwrap(URL(string: endpoint + "/api/collections/users/auth-with-password"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identity": "uitest@legulus.example", "password": "legulus-uitest-1"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try Token(XCTUnwrap(json["token"] as? String))
    }

    func testCreate_BackendKeepsTheValuesAndFeaturesTheAppDelivers() async throws {
        try XCTSkipUnless(
            Bundle.main.bundleIdentifier == "app.legulus.test",
            "Läuft nur im Scheme Legulus-Test gegen die Test-Instanz."
        )
        let auth = try await signIn()
        let database = try Database(inMemory: ())
        let store = LocalSampleStore(
            database: database, userId: "u1", timeZone: .gmt, settings: { SampleIDSettings(cutoffHour: 5) }
        )
        let features = LocalSampleFeatureStore(database: database)
        let mutations = PendingMutationsStore(database: database)
        // 2026-05-19 12:00 UTC: long past, so the answer is final.
        let begin = Date(timeIntervalSince1970: 1_779_192_000)
        let sample = try store.createLocal(
            lat: 49.681616, lon: 10.039652, elevation: 250, collectedFrom: begin,
            overrideCode: "T-" + UUID().uuidString.prefix(8)
        )
        let endpoint = endpoint
        let runner = SyncRunner(
            store: store,
            mutationsStore: mutations,
            placemarkStore: LocalPlacemarkStore(database: database),
            featureStore: features,
            endpointProvider: { endpoint },
            authProvider: { auth },
            retryInterval: .seconds(3600),
            enrichmentPollInterval: .milliseconds(10),
            enrichmentPollBudget: .milliseconds(50),
            conditionsResolver: {
                SampleConditionsResolver(
                    tempus: StubTempus(), samples: store, features: features, isNightFieldtrip: { _ in false }
                )
            }
        )
        runner.kick()
        for _ in 0 ..< 500 {
            try? await Task.sleep(for: .milliseconds(20))
            if runner.isIdleForTest { break }
        }

        let local = try XCTUnwrap(store.fetchById(sample.id))
        let backendID = try XCTUnwrap(local.backendId, "create did not reach the test instance: \(local.syncError ?? "")")
        let mine = try XCTUnwrap(local.conditions)
        XCTAssertFalse(mine.needsPush)

        let server = try await SampleClient(endpoint: endpoint, auth: auth).fetchSample(id: backendID)
        let theirs = try XCTUnwrap(server.conditions, "the backend holds no conditions")
        XCTAssertEqual(theirs.status, .final)
        XCTAssertEqual(theirs.fields, mine.fields)
        XCTAssertEqual(theirs.number("weather_temperature_c"), 0, "0 °C survives the round trip")
        XCTAssertEqual(theirs.number("weather_wind_speed_kmh"), 7.4)
        XCTAssertEqual(theirs.text("moon_phase"), "Neumond")
        XCTAssertEqual(theirs.date("sunrise"), mine.date("sunrise"))
        XCTAssertTrue(ConditionsQuery.sameInstant(theirs.queriedFor, begin))
        XCTAssertTrue(ConditionsQuery.sameInstant(theirs.fetchedAt, mine.fetchedAt))

        let remote = try await SampleFeaturesClient(endpoint: endpoint, auth: auth)
            .fetchFeatures(sampleBackendIDs: [backendID])
        XCTAssertEqual(
            Set(remote.map(\.sourceID).filter { FeatureScope.tempus.contains(sourceID: $0) }),
            ["tempus:weather", "tempus:sun", "tempus:moon"]
        )
    }
}
