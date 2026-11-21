@testable import Legulus
import XCTest

final class TempusClientTests: XCTestCase {
    private func at(_ iso: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(f.date(from: iso))
    }

    private func items(_ request: URLRequest) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    /// The same request the backend sends: six decimals, the height in
    /// whole metres, the instant in UTC.
    func testRequest() throws {
        let client = try XCTUnwrap(TempusClient.make(endpoint: "https://tempus.example"))
        let request = try client.makeRequest(
            lat: 48.1351, lon: 11.582, elevationMetres: 520, at: at("2026-07-01T14:00:00+02:00")
        )
        XCTAssertEqual(request.url?.host, "tempus.example")
        XCTAssertEqual(request.url?.path, "/api/v1/query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(try items(request), [
            "lat": "48.135100", "lon": "11.582000", "elevation": "520", "datetime": "2026-07-01T12:00:00Z"
        ])
    }

    func testRequest_NegativeElevationAndTrailingSlash() throws {
        let client = try XCTUnwrap(TempusClient.make(endpoint: " https://tempus.example/ "))
        let request = try client.makeRequest(lat: 31.5, lon: 35.47, elevationMetres: -412, at: at("2026-07-01T12:00:00Z"))
        XCTAssertEqual(request.url?.path, "/api/v1/query")
        XCTAssertEqual(try items(request)["elevation"], "-412")
    }

    /// An empty endpoint switches the on-device query off.
    func testMake_EmptyEndpointIsNil() {
        XCTAssertNil(TempusClient.make(endpoint: ""))
        XCTAssertNil(TempusClient.make(endpoint: "   "))
    }

    func testInvalidEndpointThrows() throws {
        let client = try XCTUnwrap(TempusClient.make(endpoint: "kein endpoint"))
        XCTAssertThrowsError(try client.makeRequest(lat: 1, lon: 1, elevationMetres: 0, at: Date()))
    }
}
