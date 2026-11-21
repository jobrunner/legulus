import Foundation

/// Subset of Tempus' `GET /api/v1/query` response we consume. Mirrors Go
/// `services.TempusResponse`; unknown fields are ignored.
public struct TempusResponse: Decodable, Equatable, Sendable {
    /// One GeoJSON feature (weather, dewpoint, sun, moon, aggregate,
    /// bioclim). Properties and license are kept as delivered.
    public struct Feature: Decodable, Equatable, Sendable {
        public var properties: [String: JSONValue]
        public var license: JSONValue?

        public init(properties: [String: JSONValue], license: JSONValue?) {
            self.properties = properties
            self.license = license
        }

        private enum CodingKeys: String, CodingKey { case properties, license }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            properties = (try? c.decode([String: JSONValue].self, forKey: .properties)) ?? [:]
            license = try? c.decode(JSONValue.self, forKey: .license)
        }

        /// `properties.kind`, or "" when it is missing.
        public var kind: String {
            if case let .string(kind)? = properties["kind"] { return kind }
            return ""
        }
    }

    /// The outcome of one provider. Tempus answers 200 even when a
    /// provider failed; the failure is reported here.
    public struct Provider: Decodable, Equatable, Sendable {
        public static let unavailable = "unavailable"

        public var id: String
        public var kind: String
        public var status: String
        /// A Go duration string ("2h0m0s"), only with `unavailable`.
        public var retryAfter: String?

        public init(id: String, kind: String, status: String, retryAfter: String?) {
            self.id = id
            self.kind = kind
            self.status = status
            self.retryAfter = retryAfter
        }

        private enum CodingKeys: String, CodingKey { case id, kind, status, retryAfter }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
            kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
            status = (try? c.decode(String.self, forKey: .status)) ?? ""
            retryAfter = try? c.decode(String.self, forKey: .retryAfter)
        }

        /// `retryAfter` in seconds; nil without a usable hint.
        public var retryAfterSeconds: TimeInterval? {
            Self.goDuration(retryAfter ?? "")
        }

        /// Parses a Go duration made of h, m and s parts ("2h0m0s",
        /// "1.5s"). Anything else, and a duration that is not positive,
        /// counts as no hint.
        static func goDuration(_ text: String) -> TimeInterval? {
            var total: TimeInterval = 0
            var number = ""
            var sawUnit = false
            for ch in text {
                switch ch {
                case "0" ... "9", ".":
                    number.append(ch)
                case "h", "m", "s":
                    guard let value = Double(number) else { return nil }
                    total += value * (ch == "h" ? 3600 : ch == "m" ? 60 : 1)
                    number = ""
                    sawUnit = true
                default:
                    return nil
                }
            }
            guard sawUnit, number.isEmpty, total > 0 else { return nil }
            return total
        }
    }

    public var features: [Feature]
    public var providers: [Provider]

    public init(features: [Feature], providers: [Provider]) {
        self.features = features
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey { case features, providers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        features = (try? c.decode([Feature].self, forKey: .features)) ?? []
        providers = (try? c.decode([Provider].self, forKey: .providers)) ?? []
    }
}
