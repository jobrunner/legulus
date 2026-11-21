import Foundation

/// State of a sample's weather, climate and astronomy values
/// (`samples.conditions_status`).
public enum ConditionsStatus: String, Codable, Sendable {
    /// Coordinate there, no answer from Tempus yet.
    case pending
    /// An answer that will be replaced: a provider was unavailable, or
    /// the instant was younger than five days (forecast data) or in the
    /// future when it was fetched.
    case provisional
    case final
}

/// One value Tempus delivered for a sample field.
public enum ConditionsValue: Equatable, Sendable {
    case number(Double)
    case text(String)
    case date(Date)
}

/// A Tempus answer mapped onto a sample.
public struct ConditionsResult: Equatable, Sendable {
    public var status: ConditionsStatus
    public var queriedFor: Date
    public var fetchedAt: Date
    /// When to ask again; nil for a final result.
    public var retryAt: Date?
    /// Only the fields Tempus delivered, keyed by the backend's column
    /// names. A number column counts only when it is listed here: 0 °C
    /// is a real value.
    public var values: [String: ConditionsValue]
    /// One row per Tempus feature, `sourceID` "tempus:<kind>".
    public var features: [OrtusFeature]

    public init(
        status: ConditionsStatus, queriedFor: Date, fetchedAt: Date, retryAt: Date?,
        values: [String: ConditionsValue], features: [OrtusFeature]
    ) {
        self.status = status
        self.queriedFor = queriedFor
        self.fetchedAt = fetchedAt
        self.retryAt = retryAt
        self.values = values
        self.features = features
    }

    /// The delivered fields, sorted (`conditions_fields`).
    public var fields: [String] { values.keys.sorted() }
}

/// Maps a Tempus answer onto sample fields, status and features. A port
/// of `tabularius/internal/conditions/map.go` (`FromTempus`): the app
/// queries Tempus itself when it is online, and what it stores must be
/// what the backend would have stored. Change both together.
public enum ConditionsMapper {
    /// `source_id` prefix of every Tempus feature row.
    public static let featureSourcePrefix = "tempus:"
    static let featureSourceName = "Tempus"

    /// Wait when a provider is unavailable without a hint, and after an
    /// instant that still lies in the future.
    static let defaultRetry: TimeInterval = 3600

    /// How a value field is stored.
    public enum ValueType: Sendable { case number, text, date }

    private struct Spec {
        let field: String
        let kind: String
        let path: [String]
        let type: ValueType
    }

    private static let specs: [Spec] = [
        Spec(field: "weather_temperature_c", kind: "weather", path: ["temperature2m"], type: .number),
        Spec(field: "weather_humidity_pct", kind: "weather", path: ["relativeHumidity2m"], type: .number),
        Spec(field: "weather_dew_point_c", kind: "dewpoint", path: ["dewPoint2m"], type: .number),
        Spec(field: "weather_precipitation_mm", kind: "weather", path: ["precipitation"], type: .number),
        Spec(field: "weather_wind_speed_kmh", kind: "weather", path: ["windSpeed10m"], type: .number),
        Spec(field: "weather_cloud_cover_pct", kind: "weather", path: ["cloudCover"], type: .number),
        Spec(field: "weather_code", kind: "weather", path: ["weatherCode"], type: .number),
        Spec(field: "precipitation_24h_mm", kind: "aggregate", path: ["precipitation", "last24h"], type: .number),
        Spec(field: "precipitation_72h_mm", kind: "aggregate", path: ["precipitation", "last72h"], type: .number),
        Spec(field: "precipitation_120h_mm", kind: "aggregate", path: ["precipitation", "last120h"], type: .number),
        Spec(field: "day_temperature_min_c", kind: "aggregate", path: ["temperatureDay", "min"], type: .number),
        Spec(field: "day_temperature_max_c", kind: "aggregate", path: ["temperatureDay", "max"], type: .number),
        Spec(field: "day_temperature_mean_c", kind: "aggregate", path: ["temperatureDay", "mean"], type: .number),
        Spec(field: "climate_koppen_code", kind: "bioclim", path: ["koppen", "code"], type: .text),
        Spec(field: "climate_altitudinal_belt", kind: "bioclim", path: ["altitudinalBelt", "belt", "de"], type: .text),
        Spec(field: "sunrise", kind: "sun", path: ["sunrise"], type: .date),
        Spec(field: "sunset", kind: "sun", path: ["sunset"], type: .date),
        Spec(field: "moon_phase", kind: "moon", path: ["phase", "de"], type: .text),
        Spec(field: "moon_illumination_pct", kind: "moon", path: ["illuminationPct"], type: .number)
    ]

    /// The sample fields that carry Tempus values, in the backend's order.
    public static let valueFields: [String] = specs.map(\.field)

    private static let types: [String: ValueType] = Dictionary(
        uniqueKeysWithValues: specs.map { ($0.field, $0.type) }
    )

    /// The type of a value field; nil for a name that is none.
    public static func fieldType(_ field: String) -> ValueType? {
        types[field]
    }

    /// The wind is stored only when Tempus reports it in km/h.
    private static let windField = "weather_wind_speed_kmh"
    private static let windProperty = "windSpeed10m"
    private static let windUnit = "km/h"

    /// Maps the answer for the instant `queriedFor`, fetched at
    /// `fetchedAt`. Every feature with kind and license is taken over,
    /// so a partial answer still fills what it can (sun and moon work
    /// for any instant).
    public static func map(_ response: TempusResponse, queriedFor: Date, fetchedAt: Date) -> ConditionsResult {
        var byKind: [String: [String: JSONValue]] = [:]
        var features: [OrtusFeature] = []
        for feature in response.features {
            let kind = feature.kind
            guard !kind.isEmpty, case let .object(license)? = feature.license, !license.isEmpty else { continue }
            byKind[kind] = feature.properties
            features.append(OrtusFeature(
                sourceID: featureSourcePrefix + kind,
                sourceName: featureSourceName,
                layer: kind,
                featureID: "",
                propertiesJSON: JSONValue.object(feature.properties).jsonString,
                licenseJSON: JSONValue.object(license).jsonString
            ))
        }

        var values: [String: ConditionsValue] = [:]
        for spec in specs {
            guard let props = byKind[spec.kind] else { continue }
            if spec.field == windField, !windInKmh(props) { continue }
            if let value = lookup(props, path: spec.path, type: spec.type) {
                values[spec.field] = value
            }
        }

        let (status, retryAt) = status(of: response.providers, queriedFor: queriedFor, fetchedAt: fetchedAt)
        return ConditionsResult(
            status: status, queriedFor: queriedFor, fetchedAt: fetchedAt,
            retryAt: retryAt, values: values, features: features
        )
    }

    /// Provisional while a provider is unavailable, the instant lies in
    /// the future, or it was younger than `finalAfter` when fetched. A
    /// provider error is final: asking again returns the same.
    private static func status(
        of providers: [TempusResponse.Provider], queriedFor: Date, fetchedAt: Date
    ) -> (ConditionsStatus, Date?) {
        let waits = providers
            .filter { $0.status == TempusResponse.Provider.unavailable }
            .map { $0.retryAfterSeconds ?? defaultRetry }
        if queriedFor > fetchedAt {
            return (.provisional, queriedFor.addingTimeInterval(defaultRetry))
        }
        if let longest = waits.max() {
            return (.provisional, fetchedAt.addingTimeInterval(longest))
        }
        if !ConditionsQuery.isFinalAge(instant: queriedFor, fetchedAt: fetchedAt) {
            return (.provisional, queriedFor.addingTimeInterval(ConditionsQuery.finalAfter))
        }
        return (.final, nil)
    }

    private static func windInKmh(_ props: [String: JSONValue]) -> Bool {
        guard case let .object(units)? = props["units"], case let .string(unit)? = units[windProperty] else {
            return true
        }
        return unit == windUnit
    }

    /// Walks `path` through nested objects and converts the leaf.
    private static func lookup(_ props: [String: JSONValue], path: [String], type: ValueType) -> ConditionsValue? {
        var current = JSONValue.object(props)
        for key in path {
            guard case let .object(object) = current, let next = object[key] else { return nil }
            current = next
        }
        switch (type, current) {
        case let (.number, .number(n)):
            return .number(n)
        case let (.text, .string(s)) where !s.isEmpty:
            return .text(s)
        case let (.date, .string(s)):
            return parseDate(s).map(ConditionsValue.date)
        default:
            return nil
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
