import Foundation
import LegulusGeo

/// Queries Tempus (weather, climate normals, astronomy) for a place,
/// its height and an instant.
protocol TempusQuerying: Sendable {
    func query(lat: Double, lon: Double, elevationMetres: Int, at: Date) async throws -> TempusResponse
}

enum TempusClientError: LocalizedError {
    case invalidEndpoint
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Tempus-Endpoint-URL ist ungültig."
        case let .http(status): "Tempus antwortete mit HTTP \(status)."
        }
    }
}

/// Talks to `GET {endpoint}/api/v1/query?lat=…&lon=…&elevation=…&datetime=…`
/// directly from the device — the same call the backend makes via
/// `internal/services/tempus.go`, minus the cache. A short timeout keeps
/// the field flow snappy: if Tempus is slow, the sample stays pending
/// and the backend fills the values after sync.
struct TempusClient: TempusQuerying {
    let endpoint: String
    let timeout: TimeInterval = 5
    var session: URLSession = .shared

    /// Returns nil for an empty endpoint — the caller then behaves as
    /// if the device were offline.
    static func make(endpoint: String) -> TempusClient? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return TempusClient(endpoint: trimmed)
    }

    func query(lat: Double, lon: Double, elevationMetres: Int, at: Date) async throws -> TempusResponse {
        let request = try makeRequest(lat: lat, lon: lon, elevationMetres: elevationMetres, at: at)
        let started = Date()
        let (data, response) = try await fetch(request)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            Log.network.warning(
                "tempus query failed: HTTP \(status, privacy: .public), \(durationMs, privacy: .public) ms"
            )
            throw TempusClientError.http(status: status)
        }
        Log.network.info("tempus query ok: \(durationMs, privacy: .public) ms")
        return try JSONDecoder().decode(TempusResponse.self, from: data)
    }

    /// `URLRequest.timeoutInterval` is an idle timeout only; the race
    /// against a sleep caps the whole round trip at `timeout`.
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let limit = timeout
        let session = session
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    /// Builds the query URL like the backend client: six decimals, the
    /// height in whole metres, the instant in UTC.
    func makeRequest(lat: Double, lon: Double, elevationMetres: Int, at: Date) throws -> URLRequest {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard var components = URLComponents(string: base + "/api/v1/query") else {
            throw TempusClientError.invalidEndpoint
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .gmt
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.6f", lat)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", lon)),
            URLQueryItem(name: "elevation", value: String(elevationMetres)),
            URLQueryItem(name: "datetime", value: formatter.string(from: at))
        ]
        guard let url = components.url, url.scheme != nil else {
            throw TempusClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
