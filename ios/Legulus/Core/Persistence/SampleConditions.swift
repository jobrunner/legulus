import Foundation
import LegulusGeo

/// The weather, climate and astronomy values of a sample (from Tempus).
/// Locally they are one JSON column of `local_samples`; on the server
/// they are the `conditions_*` fields and one column per value. The
/// values are keyed by the backend's column names
/// (`ConditionsMapper.valueFields`).
///
/// Only delivered values are held: a number column of the server counts
/// only when `conditions_fields` lists it (0 °C is a real value).
struct SampleConditions: Codable, Equatable {
    var status: ConditionsStatus
    /// The instant Tempus was asked for.
    var queriedFor: Date?
    var fetchedAt: Date?
    /// Earliest time of the next query (provisional only).
    var retryAt: Date?
    var numbers: [String: Double] = [:]
    var texts: [String: String] = [:]
    var dates: [String: Date] = [:]

    /// What the values were queried with besides the instant. Local
    /// only: together with `queriedFor` it tells whether the values
    /// still fit the sample (see `SampleConditionsResolver`). For
    /// values from the server it is the server sample's place and
    /// height.
    struct Inputs: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        var elevationMetres: Int
    }

    var inputs: Inputs?
    /// Local only: the device fetched these values itself and the
    /// server does not have them yet. The next push of the sample
    /// carries them.
    var needsPush = false

    /// Coordinate there, no answer yet.
    static let pending = SampleConditions(status: .pending)

    init(status: ConditionsStatus) {
        self.status = status
    }

    init(_ result: ConditionsResult) {
        status = result.status
        queriedFor = result.queriedFor
        fetchedAt = result.fetchedAt
        retryAt = result.retryAt
        for (field, value) in result.values {
            switch value {
            case let .number(n): numbers[field] = n
            case let .text(t): texts[field] = t
            case let .date(d): dates[field] = d
            }
        }
    }

    func number(_ field: String) -> Double? { numbers[field] }
    func text(_ field: String) -> String? { texts[field] }
    func date(_ field: String) -> Date? { dates[field] }

    /// The delivered fields, sorted (`conditions_fields`).
    var fields: [String] {
        (Array(numbers.keys) + Array(texts.keys) + Array(dates.keys)).sorted()
    }

    /// An answer from Tempus is there (possibly a partial one).
    var hasAnswer: Bool { status == .provisional || status == .final }

    // MARK: - server

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    /// Reads the flat `conditions_*` and value fields of a server
    /// sample; nil when the sample was never processed (empty status).
    static func fromServer(_ decoder: Decoder) throws -> SampleConditions? {
        let c = try decoder.container(keyedBy: Key.self)
        guard let raw = try? c.decode(String.self, forKey: Key("conditions_status")),
              let status = ConditionsStatus(rawValue: raw)
        else { return nil }
        var conditions = SampleConditions(status: status)
        guard conditions.hasAnswer else { return conditions }
        conditions.queriedFor = try? c.decode(Date.self, forKey: Key("conditions_queried_for"))
        conditions.fetchedAt = try? c.decode(Date.self, forKey: Key("conditions_fetched_at"))
        conditions.retryAt = try? c.decode(Date.self, forKey: Key("conditions_retry_at"))
        let listed = (try? c.decode([String].self, forKey: Key("conditions_fields"))) ?? []
        for field in listed {
            switch ConditionsMapper.fieldType(field) {
            case .number?:
                if let n = try? c.decode(Double.self, forKey: Key(field)) { conditions.numbers[field] = n }
            case .text?:
                if let t = try? c.decode(String.self, forKey: Key(field)), !t.isEmpty { conditions.texts[field] = t }
            case .date?:
                if let d = try? c.decode(Date.self, forKey: Key(field)) { conditions.dates[field] = d }
            case nil:
                // A field of a newer backend: not ours to show.
                continue
            }
        }
        return conditions
    }

    /// The fields the app delivers with a create or update: everything
    /// when it holds an answer, nothing otherwise (the backend then
    /// decides and enriches). Columns Tempus did not deliver are reset.
    var wireBody: [String: Any] {
        guard hasAnswer else { return [:] }
        var body: [String: Any] = [
            "conditions_status": status.rawValue,
            "conditions_fields": fields,
            "conditions_queried_for": queriedFor.map(Self.wire) ?? "",
            "conditions_fetched_at": fetchedAt.map(Self.wire) ?? "",
            "conditions_retry_at": retryAt.map(Self.wire) ?? ""
        ]
        for field in ConditionsMapper.valueFields {
            switch ConditionsMapper.fieldType(field) {
            case .number?: body[field] = numbers[field] ?? 0
            case .text?: body[field] = texts[field] ?? ""
            case .date?: body[field] = dates[field].map(Self.wire) ?? ""
            case nil: continue
            }
        }
        return body
    }

    private static func wire(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
