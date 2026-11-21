@testable import Legulus
import LegulusGeo
import XCTest

/// Canned Tempus answers for tests, trimmed to what the mapper reads.
enum TempusFixtures {
    /// Weather, sun and moon delivered; all providers ok.
    static let allOk = """
    {
      "features": [
        {"properties": {"kind": "weather", "temperature2m": 0, "relativeHumidity2m": 85,
                        "units": {"windSpeed10m": "km/h"}, "windSpeed10m": 7.4, "weatherCode": 61},
         "license": {"name": "CC-BY 4.0", "attribution": "Wetterquelle"}},
        {"properties": {"kind": "sun", "sunrise": "2026-05-19T03:27:00Z", "sunset": "2026-05-19T19:02:00Z"},
         "license": {"name": "Public Domain", "attribution": "NOAA"}},
        {"properties": {"kind": "moon", "phase": {"de": "Neumond"}, "illuminationPct": 4.5},
         "license": {"name": "Public Domain", "attribution": "Meeus"}}
      ],
      "providers": [
        {"id": "open-meteo", "kind": "weather", "status": "ok"},
        {"id": "sun", "kind": "sun", "status": "ok"},
        {"id": "moon", "kind": "moon", "status": "ok"}
      ]
    }
    """

    static func response(_ json: String = allOk) -> TempusResponse {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(TempusResponse.self, from: Data(json.utf8))
    }
}

/// Tempus stub: answers with a canned result and records the queries.
final class StubTempus: TempusQuerying, @unchecked Sendable {
    struct Query: Equatable {
        let lat: Double
        let lon: Double
        let elevationMetres: Int
        let at: Date
    }

    var result: Result<TempusResponse, Error>
    private(set) var queries: [Query] = []
    /// Runs while the request is "in flight".
    var duringQuery: (@MainActor () -> Void)?

    init(_ result: Result<TempusResponse, Error> = .success(TempusFixtures.response())) {
        self.result = result
    }

    func query(lat: Double, lon: Double, elevationMetres: Int, at: Date) async throws -> TempusResponse {
        queries.append(Query(lat: lat, lon: lon, elevationMetres: elevationMetres, at: at))
        if let duringQuery { await duringQuery() }
        return try result.get()
    }
}
